//! plang-screen — PlangOS's display and window manager.
//!
//! A minimal headless Wayland compositor. Clients (Chromium, `--ozone-platform=wayland`) draw
//! into it with shared-memory buffers; plang-screen composes them into one framebuffer and writes
//! only what changed to stdout, as binary messages [u32 length][u8 kind][payload], little-endian:
//!
//!   kind 1  one frame: [u16 count] then per rectangle [i32 x][i32 y][u32 w][u32 h][u32 n][n bytes QOI of BGRA]
//!   kind 2  the pointer to show: its CSS name, UTF-8 ("pointer", "text", "ew-resize", …)
//!   kind 3  [u64 t]: the "t" of the last input, sent right after the first frame that follows it
//!           within 300 ms (the host times input → picture with it)
//!   kind 4  [u64 t]: the same "t", sent the moment the input arrives (the pipe's round trip)
//!   kind 5  the clipboard's new text, UTF-8, when a client (or the address field) copies something
//!
//! The screen, bottom to top: the desktop (the first window: full screen), the windows, the
//! desktop's parts above the windows (its bottom BAR pixels, the taskbar, and whatever it asks for:
//! its start menu), menus (popups), a window's address field and menu.
//! plang-screen draws every window's title bar itself (server-side decorations): back, forward,
//! address; the title; minimize, maximize, close. It moves and resizes windows from their title
//! bar and edges.
//!
//! stderr, one JSON line each: {"ready":"wayland-plang"} when clients can connect, then:
//!   {"window":"opened","id","title","app"}  {"window":"titled","id","title"}
//!   {"window":"focused|minimized|maximized|restored|closed","id"}
//!   {"navigate":"what was typed","id"}      the address field's Enter; the menu's History,
//!                                           Downloads, Settings (chrome:// pages)
//!   {"open":"url","id"}                     the menu's New window
//!
//! stdin takes one JSON line each (input events are the same lines screen.open gives):
//!   {"mouse":"move|down|up|wheel","x","y","button","clicks","dx","dy"}
//!   {"key":"down|up","sc":<scancode>,"ext":<extended>,"mods":<alt 1, ctrl 2, shift 8>}
//!   {"text":"a"}           a typed character (the address field uses it)
//!   {"clipboard":"text"}   the host's clipboard; a client pastes it
//!   {"window":"focus|minimize|maximize|restore|close","id"}
//!   {"window":"url","id","url"}   the page a window shows (for its address field)
//!   {"window":"above","id":0,"x","y","w","h"}   a part of the desktop to show above the windows
//!                                              (its start menu); w 0: none
//!
//! usage: plang-screen <width> <height> [xkb-layout]      (socket in $XDG_RUNTIME_DIR)

mod frame;
mod window;

use std::io::{BufRead, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::json;
use smithay::delegate_compositor;
use smithay::delegate_cursor_shape;
use smithay::delegate_data_device;
use smithay::delegate_output;
use smithay::delegate_seat;
use smithay::delegate_shm;
use smithay::delegate_xdg_decoration;
use smithay::delegate_xdg_shell;
use smithay::input::keyboard::{FilterResult, Keycode, XkbConfig};
use smithay::input::pointer::{AxisFrame, ButtonEvent, CursorImageStatus, MotionEvent};
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::output::{Mode, Output, PhysicalProperties, Scale, Subpixel};
use smithay::reexports::calloop::channel::{channel, Event as ChannelEvent};
use smithay::reexports::calloop::generic::Generic;
use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay::reexports::calloop::{EventLoop, Interest, Mode as CMode, PostAction};
use smithay::reexports::wayland_protocols::xdg::decoration::zv1::server::zxdg_toplevel_decoration_v1::Mode as Decoration;
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_server::backend::{ClientData, ClientId, DisconnectReason};
use smithay::reexports::wayland_server::protocol::{wl_buffer, wl_output, wl_seat, wl_shm, wl_surface::WlSurface};
use smithay::reexports::wayland_server::{Client, Display, DisplayHandle, Resource};
use smithay::utils::{Logical, Point, Serial, Size, Transform, SERIAL_COUNTER};
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    with_states, BufferAssignment, CompositorClientState, CompositorHandler, CompositorState, Damage,
    SurfaceAttributes,
};
use smithay::wayland::cursor_shape::CursorShapeManagerState;
use smithay::wayland::output::{OutputHandler, OutputManagerState};
use smithay::wayland::selection::data_device::{
    request_data_device_client_selection, set_data_device_focus, set_data_device_selection, ClientDndGrabHandler,
    DataDeviceHandler, DataDeviceState, ServerDndGrabHandler,
};
use smithay::wayland::selection::{SelectionHandler, SelectionSource, SelectionTarget};
use smithay::wayland::shell::xdg::decoration::{XdgDecorationHandler, XdgDecorationState};
use smithay::wayland::shell::xdg::{PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState};
use smithay::wayland::shm::{with_buffer_contents, ShmHandler, ShmState};
use smithay::wayland::socket::ListeningSocketSource;
use smithay::wayland::tablet_manager::TabletSeatHandler;

use frame::{Address, Button, Menu, Tool, TITLE};
use window::{geometry, Part, Picture, Popup, Rect, Shown, Windows};

const SOCKET: &str = "wayland-plang";
/// The text types the clipboard offers and asks for, best first.
const TEXT: [&str; 4] = ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING"];
/// The desktop's taskbar: the bottom strip that stays over every window and that a maximized
/// window leaves free. desktop.html draws its taskbar this tall.
const BAR: i32 = 56;
/// The smallest a window can be resized to.
const MIN: (i32, i32) = (240, 160);
/// The title bar's text.
const FONT: &str = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";

/// The pointer is moving or resizing a window (its title bar or edge was pressed).
enum Grab {
    Move { id: u32, from: Point<f64, Logical>, at: Point<i32, Logical> },
    Resize { id: u32, edges: u32, from: Point<f64, Logical>, frame: Rect },
}

struct State {
    dh: DisplayHandle,
    compositor: CompositorState,
    shm: ShmState,
    xdg: XdgShellState,
    _decorations: XdgDecorationState,
    seat_state: SeatState<State>,
    seat: Seat<State>,
    _outputs: OutputManagerState,
    _cursor_shape: CursorShapeManagerState,
    data_device: DataDeviceState,
    copied: smithay::reexports::calloop::channel::Sender<String>, // text read from a client's clipboard, to stdout as kind 5
    copy: Option<&'static str>, // a client copied: the type to read, once smithay has stored the selection
    clip: String,               // the host's clipboard, for pasting into the address field
    width: i32,
    height: i32,
    font: Option<fontdue::Font>,
    windows: Windows,
    popups: Vec<Popup>,
    focused: Option<u32>, // the window with the keyboard
    grab: Option<Grab>,
    pressed: Point<f64, Logical>,    // where the last button went down
    press: Option<(u32, Button)>,    // a title bar button went down; it acts when the button comes up on it
    hover: Option<(u32, Button)>,    // the title bar button under the pointer
    cursor: Option<&'static str>,    // the pointer plang-screen shows over its own parts (None: the client's)
    address: Option<Address>,        // the address field, when open
    address_picture: Picture,
    menu: Option<Menu>,              // a window's menu, when open
    menu_picture: Picture,
    above: Option<Rect>,             // a part of the desktop above the windows (its start menu)
    screen: Vec<u8>, // what the host shows
    pending: Vec<(i32, i32, u32, u32, Vec<u8>)>, // rectangles of the frame being built (x, y, w, h, QOI), sent by flush()
    stamp: Option<(u64, Instant)>, // the host's stamp of the last input and when it came, echoed after the next frame
    callbacks: Vec<smithay::reexports::wayland_server::protocol::wl_callback::WlCallback>,
    start: Instant,
    out: std::io::BufWriter<std::io::Stdout>,
}

#[derive(Default)]
struct ClientState {
    compositor: CompositorClientState,
}
impl ClientData for ClientState {
    fn initialized(&self, _: ClientId) {}
    fn disconnected(&self, _: ClientId, _: DisconnectReason) {}
}

/// What happened, one JSON line on stderr (PlangOS's plang reads it).
fn event(what: serde_json::Value) {
    eprintln!("{}", what);
}

impl State {
    fn now(&self) -> u32 {
        self.start.elapsed().as_millis() as u32
    }

    /// The screen minus the taskbar: where windows go (their title bars included).
    fn work(&self) -> Rect {
        Rect::new((0, 0).into(), (self.width, self.height - BAR).into())
    }

    /// One binary message on stdout: [u32 length][u8 kind][payload], little-endian.
    fn message(&mut self, kind: u8, payload: &[u8]) {
        let _ = self.out.write_all(&((payload.len() + 1) as u32).to_le_bytes());
        let _ = self.out.write_all(&[kind]);
        let _ = self.out.write_all(payload);
        let _ = self.out.flush();
    }

    /// Recompose the screen inside `r` — desktop, windows with their title bars, taskbar, menus,
    /// the address field — then send `r` if anything in it changed.
    fn present(&mut self, r: Rect) {
        let (w, h) = (self.width, self.height);
        let x0 = r.loc.x.clamp(0, w);
        let y0 = r.loc.y.clamp(0, h);
        let x1 = (r.loc.x + r.size.w).clamp(0, w);
        let y1 = (r.loc.y + r.size.h).clamp(0, h);
        if x1 <= x0 || y1 <= y0 {
            return;
        }
        let row = (x1 - x0) as usize * 4;
        let mut changed = false;
        let mut rect = Vec::with_capacity(row * (y1 - y0) as usize);
        let mut line = vec![0u8; row];
        for y in y0..y1 {
            line.fill(0);
            if y >= h - BAR {
                // the taskbar: the desktop's own pixels, over every window
                if let Some(d) = self.windows.desktop() {
                    d.picture.draw(y, x0, &mut line);
                }
            } else {
                for win in self.windows.iter().filter(|win| win.visible()) {
                    if !win.desktop {
                        win.bar.draw(y, x0, &mut line);
                    }
                    win.picture.draw(y, x0, &mut line);
                }
                // the desktop's part above the windows: its pixels again, there
                if let (Some(a), Some(d)) = (self.above, self.windows.desktop()) {
                    let (ax0, ax1) = (x0.max(a.loc.x), x1.min(a.loc.x + a.size.w));
                    if y >= a.loc.y && y < a.loc.y + a.size.h && ax1 > ax0 {
                        d.picture.draw(y, ax0, &mut line[((ax0 - x0) * 4) as usize..((ax1 - x0) * 4) as usize]);
                    }
                }
            }
            for p in &self.popups {
                p.picture.draw(y, x0, &mut line);
            }
            if self.address.is_some() {
                self.address_picture.draw(y, x0, &mut line);
            }
            if self.menu.is_some() {
                self.menu_picture.draw(y, x0, &mut line);
            }
            let at = ((y * w + x0) * 4) as usize;
            if self.screen[at..at + row] != line[..] {
                self.screen[at..at + row].copy_from_slice(&line);
                changed = true;
            }
            rect.extend_from_slice(&line);
        }
        if !changed {
            return;
        }
        // QOI: fast lossless, simple to decode anywhere. The bytes are BGRA; QOI doesn't care
        // which channel is which, so they go in and come out in the same order.
        // A big area is cut into horizontal bands, encoded on all cores at once; the host decodes
        // the bands in parallel too.
        let w = (x1 - x0) as usize;
        let h = (y1 - y0) as usize;
        let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).min(8);
        let bands = if w * h >= 256 * 256 && cores > 1 { cores } else { 1 };
        let rows_per_band = h.div_ceil(bands);
        let encoded: Vec<(usize, usize, Vec<u8>)> = std::thread::scope(|s| {
            let jobs: Vec<_> = (0..h)
                .step_by(rows_per_band)
                .map(|top| {
                    let rows = rows_per_band.min(h - top);
                    let band = &rect[top * w * 4..(top + rows) * w * 4];
                    s.spawn(move || (top, rows, qoi::encode_to_vec(band, w as u32, rows as u32).unwrap_or_default()))
                })
                .collect();
            jobs.into_iter().map(|j| j.join().unwrap()).collect()
        });
        for (top, rows, qoi) in encoded {
            self.pending.push((x0, y0 + top as i32, w as u32, rows as u32, qoi));
        }
    }

    /// One message per frame, kind 1: [u16 count] then per rectangle
    /// [i32 x][i32 y][u32 w][u32 h][u32 n][n bytes QOI]. Binary all the way: no base64, no JSON.
    fn flush(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        let size: usize = 2 + self.pending.iter().map(|p| 20 + p.4.len()).sum::<usize>();
        let mut payload = Vec::with_capacity(size);
        payload.extend_from_slice(&(self.pending.len() as u16).to_le_bytes());
        for (x, y, w, h, qoi) in self.pending.drain(..) {
            payload.extend_from_slice(&x.to_le_bytes());
            payload.extend_from_slice(&y.to_le_bytes());
            payload.extend_from_slice(&w.to_le_bytes());
            payload.extend_from_slice(&h.to_le_bytes());
            payload.extend_from_slice(&(qoi.len() as u32).to_le_bytes());
            payload.extend_from_slice(&qoi);
        }
        self.message(1, &payload);
        // kind 3: the stamp of the input this frame follows, so the host can time input → picture.
        // Only when the frame came soon after the input (300 ms): a later frame is something else
        // changing (an ad), not the answer to this input.
        if let Some((t, at)) = self.stamp.take() {
            if at.elapsed() < Duration::from_millis(300) {
                self.message(3, &t.to_le_bytes());
            }
        }
    }

    /// Redraws where something was and is.
    fn redraw(&mut self, old: Rect, new: Rect) {
        if old.size.w > 0 && old.overlaps(new) {
            self.present(old.merge(new));
        } else {
            self.present(old);
            self.present(new);
        }
        self.flush();
    }

    // ---- title bars and the address field -----------------------------------------------------

    /// Draws window `i`'s title bar again (its title, width, whether it is active, the hover).
    fn dress(&mut self, i: usize) {
        let win = self.windows.get(i);
        if win.desktop {
            return;
        }
        let active = self.focused == Some(win.id);
        let hover = self.hover.filter(|(id, _)| *id == win.id).map(|(_, b)| b);
        let canvas = frame::title_bar(self.font.as_ref(), win.size.w, &win.title(), active, win.shown == Shown::Maximized, hover);
        let at = (win.at.x, win.at.y - TITLE);
        let visible = win.visible();
        let bar = canvas.picture(at);
        let r = bar.rect;
        self.windows.get_mut(i).bar = bar;
        if visible {
            self.present(r);
            self.flush();
        }
    }

    fn dress_id(&mut self, id: Option<u32>) {
        if let Some(i) = id.and_then(|id| self.windows.by_id(id)) {
            self.dress(i);
        }
    }

    /// Opens the address field under window `id`'s title bar, its page's address selected.
    fn open_address(&mut self, id: u32) {
        let Some(i) = self.windows.by_id(id) else { return };
        self.address = Some(Address::new(id, &self.windows.get(i).url));
        self.draw_address();
    }

    fn close_address(&mut self) {
        if self.address.take().is_some() {
            let r = self.address_picture.rect;
            self.present(r);
            self.flush();
        }
    }

    /// Opens (or closes) window `id`'s menu under its menu button.
    fn toggle_menu(&mut self, id: u32) {
        if self.menu.as_ref().map(|m| m.id) == Some(id) {
            return self.close_menu();
        }
        self.close_address();
        self.menu = Some(Menu { id, hover: None });
        self.draw_menu();
    }

    fn close_menu(&mut self) {
        if self.menu.take().is_some() {
            let r = self.menu_picture.rect;
            self.present(r);
            self.flush();
        }
    }

    fn draw_menu(&mut self) {
        let Some(menu) = &self.menu else { return };
        let Some(i) = self.windows.by_id(menu.id) else { return };
        let win = self.windows.get(i);
        let (bx, bw) = Button::Menu.span(win.size.w);
        let right = win.at.x + bx + bw;
        let canvas = menu.draw(self.font.as_ref());
        let old = self.menu_picture.rect;
        self.menu_picture = canvas.picture(((right - Menu::WIDTH - 4).max(0), win.at.y - 2));
        let new = self.menu_picture.rect;
        self.redraw(old, new);
    }

    /// A menu item: Chromium's tool, by its keys (to that window) or its page (opened by PLang).
    fn tool(&mut self, id: u32, tool: Tool) {
        let Some(i) = self.windows.by_id(id) else { return };
        const CTRL: u32 = 29;
        match tool {
            Tool::NewWindow => {
                let url = self.windows.get(i).url.clone();
                if !url.is_empty() {
                    event(json!({"open": url, "id": id}));
                }
            }
            // Chromium's own pages don't open as app windows: the window goes there (Back returns)
            Tool::History => event(json!({"navigate": "chrome://history", "id": id})),
            Tool::Downloads => event(json!({"navigate": "chrome://downloads", "id": id})),
            Tool::Settings => event(json!({"navigate": "chrome://settings", "id": id})),
            Tool::Reload => self.keys(i, &[], 63),       // F5
            Tool::Find => self.keys(i, &[CTRL], 33),     // Ctrl+F
            Tool::ZoomIn => self.keys(i, &[CTRL], 78),   // Ctrl + keypad +: the same key on every layout
            Tool::ZoomOut => self.keys(i, &[CTRL], 74),  // Ctrl + keypad −
            Tool::ZoomReset => self.keys(i, &[CTRL], 11), // Ctrl+0
            Tool::Print => self.keys(i, &[CTRL], 25),    // Ctrl+P
            Tool::DevTools => self.keys(i, &[], 88),     // F12
        }
    }

    fn draw_address(&mut self) {
        let Some(address) = &self.address else { return };
        let Some(i) = self.windows.by_id(address.id) else { return };
        let win = self.windows.get(i);
        let width = (win.size.w - 40).clamp(200, 760);
        let canvas = address.draw(self.font.as_ref(), width);
        let old = self.address_picture.rect;
        self.address_picture = canvas.picture((win.at.x + 76, win.at.y - 2));
        let new = self.address_picture.rect;
        self.redraw(old, new);
    }

    /// A key while the address field is open: it edits the text; Enter navigates, Esc closes.
    fn address_key(&mut self, sc: u32, ext: bool, mods: u32) {
        let Some(address) = self.address.as_mut() else { return };
        let ctrl = mods & 2 != 0;
        match (sc, ext) {
            (0x1C, _) => {
                let (id, text) = (address.id, address.text.trim().to_string());
                self.close_address();
                if !text.is_empty() {
                    event(json!({"navigate": text, "id": id}));
                }
                return;
            }
            (0x01, false) => return self.close_address(),
            (0x0E, false) => address.backspace(),
            (0x53, true) => address.delete(),
            (0x4B, true) => address.step(-1),
            (0x4D, true) => address.step(1),
            (0x47, true) => address.home(false),
            (0x4F, true) => address.home(true),
            (0x1E, false) if ctrl => address.selected = true,
            (0x2F, false) if ctrl => {
                let clip = self.clip.replace(['\r', '\n'], " ");
                address.typed(&clip);
            }
            (0x2E, false) if ctrl => {
                let text = address.text.clone();
                self.message(5, text.as_bytes());
                return;
            }
            _ => return,
        }
        self.draw_address();
    }

    /// Keys to window `i` (evdev codes): the modifiers held around one key.
    fn keys(&mut self, i: usize, held: &[u32], key: u32) {
        self.focus(i);
        let Some(keyboard) = self.seat.get_keyboard() else { return };
        use smithay::backend::input::KeyState::{Pressed, Released};
        let presses = held.iter().map(|k| (*k, Pressed))
            .chain([(key, Pressed), (key, Released)])
            .chain(held.iter().rev().map(|k| (*k, Released)));
        for (code, state) in presses.collect::<Vec<_>>() {
            let time = self.now();
            keyboard.input::<(), _>(self, Keycode::new(code + 8), state, SERIAL_COUNTER.next_serial(), time, |_, _, _| FilterResult::Forward);
        }
    }

    /// Back and forward: the keys Chromium knows for them (Alt+Left, Alt+Right), to that window.
    fn history(&mut self, i: usize, forward: bool) {
        self.keys(i, &[56], if forward { 106 } else { 105 });
    }

    /// A title bar button was clicked.
    fn act(&mut self, i: usize, button: Button) {
        match button {
            Button::Back => self.history(i, false),
            Button::Forward => self.history(i, true),
            Button::Address => {
                self.close_menu();
                let id = self.windows.get(i).id;
                self.open_address(id)
            }
            Button::Menu => {
                let id = self.windows.get(i).id;
                self.toggle_menu(id)
            }
            Button::Minimize => self.minimize(i),
            Button::Maximize => self.toggle(i),
            Button::Close => self.windows.get(i).surface.send_close(),
            Button::Title => {}
        }
    }

    /// The pointer is over `part` of window `i` (or nothing of ours): hover and pointer shape.
    fn over(&mut self, hit: Option<(usize, Part)>, panel: bool) {
        let hover = match hit {
            Some((i, Part::Bar(b))) if b != Button::Title => Some((self.windows.get(i).id, b)),
            _ => None,
        };
        if hover != self.hover {
            let before = self.hover.map(|(id, _)| id);
            self.hover = hover;
            self.dress_id(before);
            self.dress_id(hover.map(|(id, _)| id));
        }
        let cursor = match hit {
            _ if panel => Some("default"),
            Some((_, part @ (Part::Bar(_) | Part::Edge(_)))) => Some(part.cursor()),
            _ => None,
        };
        if cursor != self.cursor {
            self.cursor = cursor;
            if let Some(name) = cursor {
                self.message(2, name.as_bytes());
            }
        }
    }

    // ---- windows ------------------------------------------------------------------------------

    /// Window `i` gets the keyboard and goes on top (a minimized one shows again).
    fn focus(&mut self, i: usize) {
        let i = self.windows.raise(i);
        let was_minimized = self.windows.get(i).shown == Shown::Minimized;
        if was_minimized {
            let win = self.windows.get_mut(i);
            win.shown = win.was;
        }
        let id = self.windows.get(i).id;
        if self.focused != Some(id) {
            let before = self.focused;
            if let Some(old) = before.and_then(|f| self.windows.by_id(f)) {
                self.windows.get(old).configure(None, &[(xdg_toplevel::State::Activated, false)]);
            }
            self.windows.get(i).configure(None, &[(xdg_toplevel::State::Activated, true)]);
            self.focused = Some(id);
            let surface = self.windows.get(i).wl().clone();
            if let Some(keyboard) = self.seat.get_keyboard() {
                keyboard.set_focus(self, Some(surface), SERIAL_COUNTER.next_serial());
            }
            self.dress_id(before);
            if !self.windows.get(i).desktop {
                event(json!({"window": if was_minimized { "restored" } else { "focused" }, "id": id}));
                if was_minimized {
                    event(json!({"window": "focused", "id": id}));
                }
            }
        }
        self.dress(i);
        let r = self.windows.get(i).outer();
        self.present(r);
        self.flush();
    }

    /// The keyboard goes to whatever is on top now.
    fn focus_top(&mut self) {
        self.focused = None;
        if let Some(i) = self.windows.top() {
            self.focus(i);
        }
    }

    fn minimize(&mut self, i: usize) {
        let win = self.windows.get_mut(i);
        if win.desktop || win.shown == Shown::Minimized {
            return;
        }
        win.was = win.shown;
        win.shown = Shown::Minimized;
        let (id, r) = (win.id, win.outer());
        event(json!({"window": "minimized", "id": id}));
        if self.address.as_ref().map(|a| a.id) == Some(id) {
            self.close_address();
        }
        if self.menu.as_ref().map(|m| m.id) == Some(id) {
            self.close_menu();
        }
        self.present(r);
        self.flush();
        if self.focused == Some(id) {
            self.focus_top();
        }
    }

    fn toggle(&mut self, i: usize) {
        if self.windows.get(i).shown == Shown::Maximized {
            self.restore(i)
        } else {
            self.maximize(i)
        }
    }

    fn maximize(&mut self, i: usize) {
        let work = self.work();
        let win = self.windows.get_mut(i);
        if win.desktop || win.shown == Shown::Maximized {
            return;
        }
        win.restore = win.frame();
        win.shown = Shown::Maximized;
        win.at = (work.loc.x, work.loc.y + TITLE).into();
        win.configure(Some((work.size.w, work.size.h - TITLE).into()), &[(xdg_toplevel::State::Maximized, true)]);
        event(json!({"window": "maximized", "id": win.id}));
    }

    fn restore(&mut self, i: usize) {
        let win = self.windows.get_mut(i);
        match win.shown {
            Shown::Minimized => self.focus(i),
            Shown::Maximized => {
                win.shown = Shown::Normal;
                win.at = win.restore.loc;
                win.configure(Some(win.restore.size), &[(xdg_toplevel::State::Maximized, false)]);
                event(json!({"window": "restored", "id": win.id}));
            }
            Shown::Normal => {}
        }
    }

    /// A window closed (or its client went away).
    fn closed(&mut self, i: usize) {
        let gone = self.windows.remove(i);
        if !gone.desktop {
            event(json!({"window": "closed", "id": gone.id}));
        }
        if self.address.as_ref().map(|a| a.id) == Some(gone.id) {
            self.close_address();
        }
        if self.menu.as_ref().map(|m| m.id) == Some(gone.id) {
            self.close_menu();
        }
        self.present(gone.outer());
        self.flush();
        if self.focused == Some(gone.id) {
            self.focus_top();
        }
    }

    /// PlangOS's plang tells a window what to do (the taskbar), or what page it shows.
    fn command(&mut self, e: &serde_json::Value) {
        let what = e.get("window").and_then(|v| v.as_str()).unwrap_or("");
        let id = e.get("id").and_then(|v| v.as_f64()).unwrap_or(-1.0) as u32;
        let Some(i) = self.windows.by_id(id) else { return };
        match what {
            "focus" => self.focus(i),
            "minimize" => self.minimize(i),
            "maximize" => self.maximize(i),
            "restore" => self.restore(i),
            "close" => self.windows.get(i).surface.send_close(),
            "url" => self.windows.get_mut(i).url = e.get("url").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            "above" if self.windows.get(i).desktop => {
                let n = |k: &str| e.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0) as i32;
                let old = self.above.take().unwrap_or_default();
                let new = Rect::new((n("x"), n("y")).into(), (n("w"), n("h")).into());
                if new.size.w > 0 && new.size.h > 0 {
                    self.above = Some(new);
                }
                self.redraw(old, new);
            }
            _ => {}
        }
    }

    /// The pointer moved while it holds a window (moving or resizing it).
    fn drag(&mut self, x: f64, y: f64) {
        let bottom = self.height - BAR;
        match self.grab {
            Some(Grab::Move { id, from, at }) => {
                let Some(i) = self.windows.by_id(id) else { return };
                let win = self.windows.get_mut(i);
                let old = win.outer();
                win.at = (at.x + (x - from.x) as i32, (at.y + (y - from.y) as i32).clamp(TITLE, bottom - 8)).into();
                win.place();
                let new = win.outer();
                self.redraw(old, new);
            }
            Some(Grab::Resize { id, edges, from, frame }) => {
                let Some(i) = self.windows.by_id(id) else { return };
                let (dx, dy) = ((x - from.x) as i32, (y - from.y) as i32);
                let mut size = frame.size;
                if edges & 4 != 0 {
                    size.w = frame.size.w - dx; // left
                }
                if edges & 8 != 0 {
                    size.w = frame.size.w + dx; // right
                }
                if edges & 1 != 0 {
                    size.h = frame.size.h - dy; // top
                }
                if edges & 2 != 0 {
                    size.h = frame.size.h + dy; // bottom
                }
                size.w = size.w.max(MIN.0);
                size.h = size.h.max(MIN.1);
                self.windows.get(i).configure(Some(size), &[(xdg_toplevel::State::Resizing, true)]);
            }
            None => {}
        }
    }

    /// The button came up: the window is where the pointer left it.
    fn release(&mut self) {
        if let Some(Grab::Resize { id, .. }) = self.grab {
            if let Some(i) = self.windows.by_id(id) {
                self.windows.get(i).configure(None, &[(xdg_toplevel::State::Resizing, false)]);
            }
        }
        self.grab = None;
        self.press = None;
    }

    /// The pointer leaves every surface while it holds a window.
    fn hold(&mut self, grab: Grab) {
        self.grab = Some(grab);
        if let Some(pointer) = self.seat.get_pointer() {
            let location = pointer.current_location();
            pointer.motion(self, None, &MotionEvent { location, serial: SERIAL_COUNTER.next_serial(), time: self.now() });
            pointer.frame(self);
        }
    }

    /// What is at (x, y): a menu, the taskbar, a window (its page, title bar or edge), the desktop.
    fn hit(&self, x: i32, y: i32) -> Option<(usize, Part)> {
        if y >= self.height - BAR || self.above.is_some_and(|a| a.contains((x, y))) {
            return self.windows.iter().position(|w| w.desktop).map(|i| (i, Part::Content));
        }
        self.windows.hit(x, y)
    }

    /// The client surface under (x, y) and where it starts; None over plang-screen's own parts.
    fn under(&self, x: f64, y: f64) -> Option<(WlSurface, Point<f64, Logical>)> {
        let (px, py) = (x as i32, y as i32);
        for p in self.popups.iter().rev() {
            if p.picture.rect.contains((px, py)) {
                let at = p.picture.rect.loc;
                return Some((p.surface.wl_surface().clone(), (at.x as f64, at.y as f64).into()));
            }
        }
        match self.hit(px, py) {
            Some((i, Part::Content)) => {
                let win = self.windows.get(i);
                let at = win.picture.rect.loc;
                Some((win.wl().clone(), (at.x as f64, at.y as f64).into()))
            }
            _ => None,
        }
    }

    /// Reads what a client copied through a pipe, on a thread (the client writes it while the
    /// loop keeps running), then kind 5.
    fn read_copy(&mut self) {
        let Some(mime) = self.copy.take() else { return };
        let Ok((read, write)) = std::io::pipe() else { return };
        if request_data_device_client_selection(&self.seat, mime.to_string(), write.into()).is_err() {
            return;
        }
        let copied = self.copied.clone();
        std::thread::spawn(move || {
            use std::io::Read;
            let mut bytes = Vec::new();
            let _ = read.take(16 << 20).read_to_end(&mut bytes);
            let _ = copied.send(String::from_utf8_lossy(&bytes).into_owned());
        });
    }

    fn input(&mut self, line: &str) {
        let Ok(e) = serde_json::from_str::<serde_json::Value>(line) else { return };
        if let Some(t) = e.get("t").and_then(|v| v.as_u64()) {
            // kind 4 at once: the pipe's own round trip (host → PlangOS → here → host), no browser in it
            self.message(4, &t.to_le_bytes());
            self.stamp = Some((t, Instant::now()));
        }
        let num = |k: &str| e.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0);
        let serial = SERIAL_COUNTER.next_serial();
        let time = self.now();
        if let Some(kind) = e.get("mouse").and_then(|v| v.as_str()) {
            let Some(pointer) = self.seat.get_pointer() else { return };
            let (x, y) = (num("x"), num("y"));
            if self.grab.is_some() {
                // holding a window: moves move it, the button coming up lets go
                match kind {
                    "move" => self.drag(x, y),
                    "up" => {
                        self.release();
                        let state = smithay::backend::input::ButtonState::Released;
                        pointer.button(self, &ButtonEvent { button: 0x110, state, serial, time });
                        let focus = self.under(x, y);
                        pointer.motion(self, focus, &MotionEvent { location: (x, y).into(), serial, time });
                        pointer.frame(self);
                    }
                    _ => {}
                }
                return;
            }
            let (px, py) = (x as i32, y as i32);
            let hit = self.hit(px, py);
            let on_menu = self.popups.iter().any(|p| p.picture.rect.contains((px, py)));
            let on_address = self.address.is_some() && self.address_picture.rect.contains((px, py));
            let on_tools = self.menu.is_some() && self.menu_picture.rect.contains((px, py));
            let panel = on_address || on_tools;
            let ours = if on_menu || panel { None } else { hit.filter(|(_, p)| *p != Part::Content) };
            let focus = if panel { None } else { self.under(x, y) };
            pointer.motion(self, focus, &MotionEvent { location: (x, y).into(), serial, time });
            self.over(ours, panel);
            if kind == "down" {
                self.pressed = (x, y).into();
                if !on_address {
                    self.close_address();
                }
                // the menu button toggles it itself
                let on_menu_button = matches!(ours, Some((_, Part::Bar(Button::Menu))));
                if !on_tools && !on_menu_button {
                    self.close_menu();
                }
                // the desktop's part above the windows goes when a click lands elsewhere
                if self.above.is_some_and(|a| !a.contains((px, py))) {
                    let old = self.above.take().unwrap_or_default();
                    self.present(old);
                    self.flush();
                }
            }
            if on_tools {
                let pic = self.menu_picture.rect;
                let item = Menu::at(py - pic.loc.y).filter(|_| px >= pic.loc.x + 4 && px < pic.loc.x + 4 + Menu::WIDTH);
                if let Some(menu) = self.menu.as_mut() {
                    if menu.hover != item {
                        menu.hover = item;
                        self.draw_menu();
                    }
                }
                if kind == "up" {
                    if let (Some(n), Some(id)) = (item, self.menu.as_ref().map(|m| m.id)) {
                        self.close_menu();
                        if let Some((_, _, tool)) = Menu::ITEMS[n] {
                            self.tool(id, tool);
                        }
                    }
                }
                pointer.frame(self);
                return;
            }
            if on_address {
                let pic = self.address_picture.rect;
                let on_copy = Address::on_copy(px - pic.loc.x, pic.size.w - 8);
                if let Some(address) = self.address.as_mut() {
                    let changed = address.copy_hover != on_copy;
                    address.copy_hover = on_copy;
                    let copy = kind == "down" && on_copy;
                    if copy {
                        address.copied = true;
                    }
                    let text = address.text.clone();
                    if copy {
                        self.message(5, text.as_bytes()); // to the host's clipboard
                    }
                    if changed || copy {
                        self.draw_address();
                    }
                }
                pointer.frame(self);
                return;
            }
            // plang-screen's own parts: the title bar and the edges
            if let Some((i, part)) = ours {
                let id = self.windows.get(i).id;
                match (kind, part) {
                    ("down", Part::Bar(Button::Title)) => {
                        self.focus(i);
                        if num("clicks") >= 2.0 {
                            self.toggle(i);
                        } else if self.windows.get(i).shown == Shown::Normal {
                            let at = self.windows.get(i).at;
                            self.hold(Grab::Move { id, from: self.pressed, at });
                        }
                    }
                    ("down", Part::Bar(b)) => {
                        self.focus(i);
                        self.press = Some((id, b));
                    }
                    ("up", Part::Bar(b)) => {
                        if self.press.take() == Some((id, b)) {
                            if let Some(i) = self.windows.by_id(id) {
                                self.act(i, b);
                            }
                        }
                    }
                    ("down", Part::Edge(edges)) => {
                        self.focus(i);
                        let frame = self.windows.get(i).frame();
                        self.hold(Grab::Resize { id, edges, from: self.pressed, frame });
                    }
                    _ => {}
                }
                pointer.frame(self);
                return;
            }
            match kind {
                "down" | "up" => {
                    if kind == "down" {
                        // a click on a window brings it forward and gives it the keyboard
                        if let (false, Some((i, _))) = (on_menu, hit) {
                            self.focus(i);
                        }
                    } else {
                        self.press = None;
                    }
                    let button = match e.get("button").and_then(|v| v.as_str()) {
                        Some("right") => 0x111,
                        Some("middle") => 0x112,
                        Some("back") => 0x113,    // BTN_SIDE: Chromium goes back
                        Some("forward") => 0x114, // BTN_EXTRA: Chromium goes forward
                        _ => 0x110,
                    };
                    let state = if kind == "down" {
                        smithay::backend::input::ButtonState::Pressed
                    } else {
                        smithay::backend::input::ButtonState::Released
                    };
                    pointer.button(self, &ButtonEvent { button, state, serial, time });
                }
                "wheel" => {
                    use smithay::backend::input::{Axis, AxisSource};
                    let mut frame = AxisFrame::new(time).source(AxisSource::Wheel);
                    let (dx, dy) = (num("dx"), num("dy"));
                    if dy != 0.0 {
                        frame = frame.value(Axis::Vertical, dy / 8.0).v120(Axis::Vertical, dy as i32);
                    }
                    if dx != 0.0 {
                        frame = frame.value(Axis::Horizontal, dx / 8.0).v120(Axis::Horizontal, dx as i32);
                    }
                    pointer.axis(self, frame);
                }
                _ => {}
            }
            pointer.frame(self);
        } else if let Some(kind) = e.get("key").and_then(|v| v.as_str()) {
            let sc = num("sc") as u32;
            let ext = e.get("ext").and_then(|v| v.as_bool()).unwrap_or(false);
            if self.menu.is_some() && kind == "down" {
                self.close_menu();
                if sc == 0x01 {
                    return; // Esc only closes the menu
                }
            }
            if self.address.is_some() {
                // the address field has the keyboard
                if kind == "down" {
                    self.address_key(sc, ext, num("mods") as u32);
                }
                return;
            }
            let Some(keyboard) = self.seat.get_keyboard() else { return };
            let Some(evdev) = evdev(sc, ext) else { return };
            let state = if kind == "down" {
                smithay::backend::input::KeyState::Pressed
            } else {
                smithay::backend::input::KeyState::Released
            };
            keyboard.input::<(), _>(self, Keycode::new(evdev + 8), state, serial, time, |_, _, _| FilterResult::Forward);
        } else if let Some(text) = e.get("text").and_then(|v| v.as_str()) {
            // typed characters: only the address field uses them (clients take keys)
            if let Some(address) = self.address.as_mut() {
                address.typed(text);
                self.draw_address();
            }
        } else if let Some(text) = e.get("clipboard").and_then(|v| v.as_str()) {
            // the host copied: that text is now the clipboard here; a client reads it on paste
            self.clip = text.to_string();
            let types = TEXT.iter().map(|t| t.to_string()).collect();
            set_data_device_selection(&self.dh, &self.seat, types, Arc::new(text.to_string()));
        } else if e.get("window").is_some() {
            self.command(&e);
        }
    }
}

/// Windows (PS/2 set 1) scancodes → Linux evdev keycodes. Plain keys are the same number;
/// extended (E0) keys differ.
fn evdev(sc: u32, ext: bool) -> Option<u32> {
    if sc == 0 {
        return None;
    }
    if !ext {
        return Some(sc);
    }
    Some(match sc {
        0x1C => 96,  // keypad Enter
        0x1D => 97,  // right Ctrl
        0x35 => 98,  // keypad /
        0x38 => 100, // right Alt (AltGr)
        0x47 => 102, // Home
        0x48 => 103, // Up
        0x49 => 104, // Page Up
        0x4B => 105, // Left
        0x4D => 106, // Right
        0x4F => 107, // End
        0x50 => 108, // Down
        0x51 => 109, // Page Down
        0x52 => 110, // Insert
        0x53 => 111, // Delete
        0x5B => 125, // left Windows
        0x5C => 126, // right Windows
        0x5D => 127, // Menu
        other => other,
    })
}

// ---- Wayland handlers -------------------------------------------------------------------------

impl CompositorHandler for State {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor
    }
    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        &client.get_data::<ClientState>().unwrap().compositor
    }
    fn commit(&mut self, surface: &WlSurface) {
        let window = self.windows.of(surface);
        let popup = self.popups.iter().position(|p| p.surface.wl_surface() == surface);

        let (buffer, damage, callbacks) = with_states(surface, |states| {
            let mut guard = states.cached_state.get::<SurfaceAttributes>();
            let attrs = guard.current();
            (attrs.buffer.take(), std::mem::take(&mut attrs.damage), std::mem::take(&mut attrs.frame_callbacks))
        });
        let Some(BufferAssignment::NewBuffer(buffer)) = buffer else {
            self.callbacks.extend(callbacks); // nothing new to show: answered on the 60 Hz tick
            return;
        };
        if window.is_none() && popup.is_none() {
            buffer.release();
            self.callbacks.extend(callbacks);
            return;
        }
        // Answered as soon as this update is on its way (see the end of commit), not on the next
        // tick: the client starts its next frame up to 16 ms sooner.
        let answer_now = callbacks;

        let mut picture = Picture::default();
        let _ = with_buffer_contents(&buffer, |ptr, len, d| {
            let stride = d.stride as usize;
            let (bw, bh) = (d.width as usize, d.height as usize);
            let data = unsafe { std::slice::from_raw_parts(ptr, len) };
            picture.pixels.reserve(bw * bh * 4);
            for y in 0..bh {
                let start = d.offset as usize + y * stride;
                if start + bw * 4 <= data.len() {
                    picture.pixels.extend_from_slice(&data[start..start + bw * 4]);
                }
            }
            picture.rect.size = (bw as i32, bh as i32).into();
            picture.opaque = d.format != wl_shm::Format::Argb8888;
        });
        buffer.release();
        let geo = geometry(surface).unwrap_or(Rect::new((0, 0).into(), picture.rect.size));

        if let Some(i) = window {
            let grab = match self.grab {
                Some(Grab::Resize { id, edges, frame, .. }) if id == self.windows.get(i).id => Some((edges, frame)),
                _ => None,
            };
            let win = self.windows.get_mut(i);
            let old = if win.picture.is_empty() || win.shown == Shown::Minimized { Rect::default() } else { win.outer() };
            let first = win.picture.is_empty();
            let resized = win.size != geo.size;
            win.offset = geo.loc;
            win.size = geo.size;
            win.picture = picture;
            if let Some((edges, frame)) = grab {
                // resizing from the left or top: the opposite edge stays where it was
                if edges & 4 != 0 {
                    win.at.x = frame.loc.x + frame.size.w - win.size.w;
                }
                if edges & 1 != 0 {
                    win.at.y = frame.loc.y + frame.size.h - win.size.h;
                }
            }
            win.place();
            let new = win.outer();
            let minimized = win.shown == Shown::Minimized;
            if first || resized {
                self.dress(i);
            }
            if self.address.as_ref().map(|a| a.id) == Some(self.windows.get(i).id) {
                self.draw_address();
            }
            if !minimized {
                if first || old != new {
                    self.redraw(old, new);
                } else {
                    let content = self.windows.get(i).picture.rect;
                    let rects: Vec<Rect> = damage
                        .iter()
                        .map(|d| match d {
                            Damage::Surface(r) => *r,
                            Damage::Buffer(r) => Rect::new((r.loc.x, r.loc.y).into(), (r.size.w, r.size.h).into()),
                        })
                        .collect();
                    if rects.is_empty() || rects.len() > 16 {
                        self.present(content);
                    } else {
                        for r in rects {
                            self.present(Rect::new(r.loc + content.loc, r.size));
                        }
                    }
                    self.flush();
                }
            }
        } else if let Some(i) = popup {
            // a menu sits where its parent (a window or another menu) says, inside its geometry
            let loc = self.popups[i].surface.with_pending_state(|s| s.geometry.loc);
            let parent = self.popups[i].surface.get_parent_surface();
            let origin = parent
                .and_then(|p| {
                    self.windows.of(&p).map(|w| self.windows.get(w).at).or_else(|| {
                        self.popups.iter().find(|q| q.surface.wl_surface() == &p).map(|q| q.picture.rect.loc)
                    })
                })
                .unwrap_or_default();
            picture.rect.loc = origin + loc - geo.loc;
            let old = self.popups[i].picture.rect;
            self.popups[i].picture = picture;
            let new = self.popups[i].picture.rect;
            self.redraw(old, new);
        }
        let t = self.now();
        for cb in answer_now {
            cb.done(t);
        }
    }
}

impl BufferHandler for State {
    fn buffer_destroyed(&mut self, _buffer: &wl_buffer::WlBuffer) {}
}
impl ShmHandler for State {
    fn shm_state(&self) -> &ShmState {
        &self.shm
    }
}

impl XdgShellHandler for State {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg
    }
    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let work = self.work();
        let desktop = self.windows.desktop().is_none() && self.windows.count() == 0;
        let (at, size): (Point<i32, Logical>, Size<i32, Logical>) = if desktop {
            ((0, 0).into(), (self.width, self.height).into())
        } else {
            // cascade new windows from the top left; `at` is the page, its title bar above it
            let n = (self.windows.count() % 8) as i32;
            ((80 + 36 * n, 40 + TITLE + 36 * n).into(), ((work.size.w - 240).min(1280), (work.size.h - 160 - TITLE).min(800)).into())
        };
        let i = self.windows.add(surface, at, size);
        let win = self.windows.get(i);
        if win.desktop {
            win.configure(Some(size), &[(xdg_toplevel::State::Fullscreen, true)]);
        } else {
            win.configure(Some(size), &[]);
            event(json!({"window": "opened", "id": win.id, "title": win.title(), "app": win.app()}));
        }
        self.focus(i);
    }
    fn new_popup(&mut self, surface: PopupSurface, positioner: PositionerState) {
        let geometry = positioner.get_geometry();
        surface.with_pending_state(|s| s.geometry = geometry);
        let _ = surface.send_configure();
        self.popups.push(Popup { surface, picture: Picture::default() });
    }
    fn grab(&mut self, _surface: PopupSurface, _seat: wl_seat::WlSeat, _serial: Serial) {}
    fn reposition_request(&mut self, surface: PopupSurface, positioner: PositionerState, token: u32) {
        let geometry = positioner.get_geometry();
        surface.with_pending_state(|s| {
            s.geometry = geometry;
            s.positioner = positioner;
        });
        surface.send_repositioned(token);
    }
    fn popup_destroyed(&mut self, surface: PopupSurface) {
        if let Some(i) = self.popups.iter().position(|p| p.surface == surface) {
            let gone = self.popups.remove(i);
            self.present(gone.picture.rect); // what was under it shows again
            self.flush();
        }
    }
    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        if let Some(i) = self.windows.of(surface.wl_surface()) {
            self.closed(i);
        }
    }
    fn title_changed(&mut self, surface: ToplevelSurface) {
        if let Some(i) = self.windows.of(surface.wl_surface()) {
            let win = self.windows.get(i);
            if !win.desktop {
                event(json!({"window": "titled", "id": win.id, "title": win.title()}));
                if !win.picture.is_empty() {
                    self.dress(i);
                }
            }
        }
    }

    // A client that draws its own frame may still ask to be moved or resized.
    fn move_request(&mut self, surface: ToplevelSurface, _seat: wl_seat::WlSeat, _serial: Serial) {
        let Some(i) = self.windows.of(surface.wl_surface()) else { return };
        let win = self.windows.get(i);
        if win.desktop || win.shown != Shown::Normal {
            return;
        }
        let grab = Grab::Move { id: win.id, from: self.pressed, at: win.at };
        self.hold(grab);
    }
    fn resize_request(&mut self, surface: ToplevelSurface, _seat: wl_seat::WlSeat, _serial: Serial, edges: xdg_toplevel::ResizeEdge) {
        let Some(i) = self.windows.of(surface.wl_surface()) else { return };
        let win = self.windows.get(i);
        if win.desktop || win.shown != Shown::Normal {
            return;
        }
        let grab = Grab::Resize { id: win.id, edges: edges.into(), from: self.pressed, frame: win.frame() };
        self.hold(grab);
    }
    fn maximize_request(&mut self, surface: ToplevelSurface) {
        if let Some(i) = self.windows.of(surface.wl_surface()) {
            self.maximize(i);
        }
        surface.send_pending_configure();
    }
    fn unmaximize_request(&mut self, surface: ToplevelSurface) {
        if let Some(i) = self.windows.of(surface.wl_surface()) {
            self.restore(i);
        }
        surface.send_pending_configure();
    }
    fn minimize_request(&mut self, surface: ToplevelSurface) {
        if let Some(i) = self.windows.of(surface.wl_surface()) {
            self.minimize(i);
        }
    }
    // Fullscreen: the desktop is already; a window gets the work area.
    fn fullscreen_request(&mut self, surface: ToplevelSurface, _output: Option<wl_output::WlOutput>) {
        match self.windows.of(surface.wl_surface()) {
            Some(i) if !self.windows.get(i).desktop => self.maximize(i),
            _ => {
                surface.send_pending_configure();
            }
        }
    }
    fn unfullscreen_request(&mut self, surface: ToplevelSurface) {
        surface.send_pending_configure();
    }
}

/// Every window's frame is plang-screen's: clients are told to draw none (server-side).
impl XdgDecorationHandler for State {
    fn new_decoration(&mut self, toplevel: ToplevelSurface) {
        toplevel.with_pending_state(|s| s.decoration_mode = Some(Decoration::ServerSide));
    }
    fn request_mode(&mut self, toplevel: ToplevelSurface, _mode: Decoration) {
        toplevel.with_pending_state(|s| s.decoration_mode = Some(Decoration::ServerSide));
        if toplevel.is_initial_configure_sent() {
            toplevel.send_pending_configure();
        }
    }
    fn unset_mode(&mut self, toplevel: ToplevelSurface) {
        self.request_mode(toplevel, Decoration::ServerSide);
    }
}

impl SeatHandler for State {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;
    fn seat_state(&mut self) -> &mut SeatState<State> {
        &mut self.seat_state
    }
    fn cursor_image(&mut self, _seat: &Seat<Self>, image: CursorImageStatus) {
        if self.cursor.is_some() {
            return; // over plang-screen's own parts, its pointer shows
        }
        let name = match image {
            CursorImageStatus::Named(icon) => icon.name().to_string(),
            CursorImageStatus::Hidden => "none".to_string(),
            _ => "default".to_string(),
        };
        self.message(2, name.as_bytes()); // kind 2: the pointer's name, UTF-8
    }
    fn focus_changed(&mut self, seat: &Seat<Self>, focused: Option<&WlSurface>) {
        // the clipboard goes to the client that has the keyboard
        let client = focused.and_then(|s| self.dh.get_client(s.id()).ok());
        set_data_device_focus(&self.dh, seat, client);
    }
}

impl SelectionHandler for State {
    type SelectionUserData = Arc<String>;

    /// A client copied. smithay stores the selection after this returns, so it's read just
    /// after (State::read_copy).
    fn new_selection(&mut self, ty: SelectionTarget, source: Option<SelectionSource>, _seat: Seat<Self>) {
        if ty != SelectionTarget::Clipboard {
            return;
        }
        let offered = source.map(|s| s.mime_types()).unwrap_or_default();
        self.copy = TEXT.iter().find(|t| offered.iter().any(|o| o == *t)).copied();
    }

    /// A client pastes what the host copied: write the text into its pipe.
    fn send_selection(&mut self, _ty: SelectionTarget, _mime: String, fd: std::os::fd::OwnedFd, _seat: Seat<Self>, text: &Arc<String>) {
        let text = text.clone();
        std::thread::spawn(move || {
            let _ = std::fs::File::from(fd).write_all(text.as_bytes());
        });
    }
}
impl DataDeviceHandler for State {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device
    }
}
impl ClientDndGrabHandler for State {}
impl ServerDndGrabHandler for State {}
impl TabletSeatHandler for State {}
impl OutputHandler for State {}

delegate_compositor!(State);
delegate_shm!(State);
delegate_xdg_shell!(State);
delegate_xdg_decoration!(State);
delegate_seat!(State);
delegate_output!(State);
delegate_cursor_shape!(State);
delegate_data_device!(State);

// ---- main --------------------------------------------------------------------------------------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let width: i32 = args.get(1).and_then(|a| a.parse().ok()).unwrap_or(1920);
    let height: i32 = args.get(2).and_then(|a| a.parse().ok()).unwrap_or(1080);
    let layout = args.get(3).cloned().unwrap_or_else(|| "is".to_string());

    // Wayland needs a private runtime folder for its socket; make it if the caller only named it
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }

    let mut event_loop: EventLoop<State> = EventLoop::try_new().expect("event loop");
    let display: Display<State> = Display::new().expect("wayland display");
    let dh = display.handle();

    let compositor = CompositorState::new::<State>(&dh);
    let shm = ShmState::new::<State>(&dh, vec![]);
    let xdg = XdgShellState::new::<State>(&dh);
    let decorations = XdgDecorationState::new::<State>(&dh);
    let mut seat_state = SeatState::new();
    let mut seat = seat_state.new_wl_seat(&dh, "seat0");
    seat.add_keyboard(XkbConfig { layout: &layout, ..Default::default() }, 400, 30).expect("keyboard (xkb layout)");
    seat.add_pointer();
    let outputs = OutputManagerState::new_with_xdg_output::<State>(&dh);
    let cursor_shape = CursorShapeManagerState::new::<State>(&dh);
    let data_device = DataDeviceState::new::<State>(&dh);
    // no font: title bars without text, still usable
    let font = std::fs::read(FONT).ok().and_then(|bytes| fontdue::Font::from_bytes(bytes, fontdue::FontSettings::default()).ok());

    let output = Output::new(
        "plang-screen".into(),
        PhysicalProperties { size: (0, 0).into(), subpixel: Subpixel::Unknown, make: "PlangOS".into(), model: "screen".into() },
    );
    let _global = output.create_global::<State>(&dh);
    let mode = Mode { size: (width, height).into(), refresh: 60_000 };
    output.change_current_state(Some(mode), Some(Transform::Normal), Some(Scale::Integer(1)), Some((0, 0).into()));
    output.set_preferred(mode);

    let socket = ListeningSocketSource::with_name(SOCKET).expect("wayland socket (is XDG_RUNTIME_DIR set?)");
    event_loop
        .handle()
        .insert_source(socket, |stream, _, state| {
            let _ = state.dh.insert_client(stream, Arc::new(ClientState::default()));
        })
        .expect("socket source");
    event_loop
        .handle()
        .insert_source(Generic::new(display, Interest::READ, CMode::Level), |_, display, state| {
            unsafe {
                display.get_mut().dispatch_clients(state).ok();
            }
            Ok(PostAction::Continue)
        })
        .expect("display source");

    // input: a thread reads stdin lines into the loop; stdin closing ends plang-screen
    let (sender, lines) = channel::<String>();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            match line {
                Ok(l) => {
                    if sender.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        std::process::exit(0);
    });
    event_loop
        .handle()
        .insert_source(lines, |event, _, state| {
            if let ChannelEvent::Msg(line) = event {
                state.input(&line);
            }
        })
        .expect("input source");

    // a client's copied text, read on a thread, out as kind 5
    let (copied, texts) = channel::<String>();
    event_loop
        .handle()
        .insert_source(texts, |event, _, state| {
            if let ChannelEvent::Msg(text) = event {
                state.message(5, text.as_bytes());
            }
        })
        .expect("clipboard source");

    // frame pacing: tell clients a frame was shown, 60 times a second
    event_loop
        .handle()
        .insert_source(Timer::from_duration(Duration::from_millis(16)), |_, _, state| {
            let t = state.now();
            for cb in state.callbacks.drain(..) {
                cb.done(t);
            }
            TimeoutAction::ToDuration(Duration::from_millis(16))
        })
        .expect("frame timer");

    let mut state = State {
        dh: dh.clone(),
        compositor,
        shm,
        xdg,
        _decorations: decorations,
        seat_state,
        seat,
        _outputs: outputs,
        _cursor_shape: cursor_shape,
        data_device,
        copied,
        copy: None,
        clip: String::new(),
        width,
        height,
        font,
        windows: Windows::default(),
        popups: Vec::new(),
        focused: None,
        grab: None,
        pressed: (0.0, 0.0).into(),
        press: None,
        hover: None,
        cursor: None,
        address: None,
        address_picture: Picture::default(),
        menu: None,
        menu_picture: Picture::default(),
        above: None,
        screen: vec![0u8; (width * height * 4) as usize],
        pending: Vec::new(),
        stamp: None,
        callbacks: Vec::new(),
        start: Instant::now(),
        out: std::io::BufWriter::with_capacity(1 << 20, std::io::stdout()),
    };
    // stdout carries only frames; readiness and window events go to stderr
    eprintln!("{{\"ready\":\"{}\"}}", SOCKET);

    loop {
        if event_loop.dispatch(Some(Duration::from_millis(16)), &mut state).is_err() {
            break;
        }
        state.read_copy();
        let _ = state.dh.flush_clients();
    }
}
