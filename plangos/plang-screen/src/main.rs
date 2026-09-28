//! plang-screen — PlangOS's display.
//!
//! A minimal headless Wayland compositor. A client (Chromium, `--ozone-platform=wayland`) draws
//! into it with shared-memory buffers; plang-screen composes them into one framebuffer and writes
//! only what changed to stdout, one JSON line per rectangle:
//!
//!   {"rects":[[x,y,w,h,"<base64 QOI of BGRA rows>"],…]}        what one frame changed
//!   {"cursor":"pointer"}                                       the pointer the client wants
//!   {"ready":"wayland-plang"}                                  the socket clients connect to
//!
//! stdin takes one JSON input event per line (the same lines screen.open gives):
//!   {"mouse":"move|down|up|wheel","x","y","button","dx","dy"}
//!   {"key":"down|up","sc":<scancode>,"ext":<extended>}
//!
//! usage: plang-screen <width> <height> [xkb-layout]      (socket in $XDG_RUNTIME_DIR)

use std::io::{BufRead, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use smithay::delegate_compositor;
use smithay::delegate_cursor_shape;
use smithay::delegate_output;
use smithay::delegate_seat;
use smithay::delegate_shm;
use smithay::delegate_xdg_shell;
use smithay::input::keyboard::{FilterResult, Keycode, XkbConfig};
use smithay::input::pointer::{AxisFrame, ButtonEvent, CursorImageStatus, MotionEvent};
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::output::{Mode, Output, PhysicalProperties, Scale, Subpixel};
use smithay::reexports::calloop::channel::{channel, Event as ChannelEvent};
use smithay::reexports::calloop::generic::Generic;
use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay::reexports::calloop::{EventLoop, Interest, Mode as CMode, PostAction};
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_server::backend::{ClientData, ClientId, DisconnectReason};
use smithay::reexports::wayland_server::protocol::{wl_buffer, wl_seat, wl_surface::WlSurface};
use smithay::reexports::wayland_server::{Client, Display, DisplayHandle};
use smithay::utils::{Rectangle, Serial, Transform, SERIAL_COUNTER};
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    with_states, BufferAssignment, CompositorClientState, CompositorHandler, CompositorState, Damage,
    SurfaceAttributes,
};
use smithay::wayland::cursor_shape::CursorShapeManagerState;
use smithay::wayland::output::{OutputHandler, OutputManagerState};
use smithay::wayland::shell::xdg::{
    PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
};
use smithay::wayland::shm::{with_buffer_contents, ShmHandler, ShmState};
use smithay::wayland::socket::ListeningSocketSource;
use smithay::wayland::tablet_manager::TabletSeatHandler;

const SOCKET: &str = "wayland-plang";

struct Popup {
    surface: PopupSurface,
    rect: Rectangle<i32, smithay::utils::Logical>,
    pixels: Vec<u8>,
}

struct State {
    dh: DisplayHandle,
    compositor: CompositorState,
    shm: ShmState,
    xdg: XdgShellState,
    seat_state: SeatState<State>,
    seat: Seat<State>,
    _outputs: OutputManagerState,
    _cursor_shape: CursorShapeManagerState,
    width: i32,
    height: i32,
    toplevel: Option<ToplevelSurface>,
    base: Vec<u8>,        // the toplevel's pixels
    screen: Vec<u8>,      // what the host shows: base + popups
    popups: Vec<Popup>,
    pending: Vec<String>, // rectangles of the frame being built, sent together by flush()
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

impl State {
    fn now(&self) -> u32 {
        self.start.elapsed().as_millis() as u32
    }

    fn emit(&mut self, line: &str) {
        let _ = self.out.write_all(line.as_bytes());
        let _ = self.out.write_all(b"\n");
        let _ = self.out.flush();
    }

    /// Recompose screen = base + popups inside `r`, then send `r` if anything in it changed.
    fn present(&mut self, r: Rectangle<i32, smithay::utils::Logical>) {
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
        for y in y0..y1 {
            let mut line: Vec<u8> = self.base[((y * w + x0) * 4) as usize..((y * w + x1) * 4) as usize].to_vec();
            for p in &self.popups {
                let (px0, py0) = (p.rect.loc.x, p.rect.loc.y);
                if y < py0 || y >= py0 + p.rect.size.h {
                    continue;
                }
                let sx = x0.max(px0);
                let ex = x1.min(px0 + p.rect.size.w);
                if ex <= sx {
                    continue;
                }
                let src = (((y - py0) * p.rect.size.w + (sx - px0)) * 4) as usize;
                let dst = ((sx - x0) * 4) as usize;
                let n = ((ex - sx) * 4) as usize;
                if src + n <= p.pixels.len() {
                    line[dst..dst + n].copy_from_slice(&p.pixels[src..src + n]);
                }
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
        let packed = qoi::encode_to_vec(&rect, (x1 - x0) as u32, (y1 - y0) as u32).unwrap_or_default();
        let b64 = base64::engine::general_purpose::STANDARD.encode(packed);
        self.pending.push(format!("[{},{},{},{},\"{}\"]", x0, y0, x1 - x0, y1 - y0, b64));
    }

    /// One line per frame: every rectangle this commit changed, together. Each line is one
    /// message through plang on both sides, so fewer lines is less work per frame.
    fn flush(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        let line = format!("{{\"rects\":[{}]}}", self.pending.join(","));
        self.pending.clear();
        self.emit(&line);
    }

    /// The surface under (x, y): the topmost popup there, else the toplevel.
    fn under(&self, x: f64, y: f64) -> Option<(WlSurface, smithay::utils::Point<f64, smithay::utils::Logical>)> {
        for p in self.popups.iter().rev() {
            if p.rect.contains((x as i32, y as i32)) {
                return Some((p.surface.wl_surface().clone(), (p.rect.loc.x as f64, p.rect.loc.y as f64).into()));
            }
        }
        self.toplevel.as_ref().map(|t| (t.wl_surface().clone(), (0.0, 0.0).into()))
    }

    fn input(&mut self, line: &str) {
        let Ok(e) = serde_json::from_str::<serde_json::Value>(line) else { return };
        let num = |k: &str| e.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0);
        let serial = SERIAL_COUNTER.next_serial();
        let time = self.now();
        if let Some(kind) = e.get("mouse").and_then(|v| v.as_str()) {
            let Some(pointer) = self.seat.get_pointer() else { return };
            let (x, y) = (num("x"), num("y"));
            let focus = self.under(x, y);
            pointer.motion(self, focus, &MotionEvent { location: (x, y).into(), serial, time });
            match kind {
                "down" | "up" => {
                    let button = match e.get("button").and_then(|v| v.as_str()) {
                        Some("right") => 0x111,
                        Some("middle") => 0x112,
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
            let Some(keyboard) = self.seat.get_keyboard() else { return };
            let sc = num("sc") as u32;
            let ext = e.get("ext").and_then(|v| v.as_bool()).unwrap_or(false);
            let Some(evdev) = evdev(sc, ext) else { return };
            let state = if kind == "down" {
                smithay::backend::input::KeyState::Pressed
            } else {
                smithay::backend::input::KeyState::Released
            };
            keyboard.input::<(), _>(self, Keycode::new(evdev + 8), state, serial, time, |_, _, _| FilterResult::Forward);
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
        // which layer this surface is: the toplevel, a popup, or neither (cursor, subsurface)
        let is_top = self.toplevel.as_ref().map(|t| t.wl_surface() == surface).unwrap_or(false);
        let popup = self.popups.iter().position(|p| p.surface.wl_surface() == surface);

        let (buffer, damage, callbacks) = with_states(surface, |states| {
            let mut guard = states.cached_state.get::<SurfaceAttributes>();
            let attrs = guard.current();
            (attrs.buffer.take(), std::mem::take(&mut attrs.damage), std::mem::take(&mut attrs.frame_callbacks))
        });
        self.callbacks.extend(callbacks);
        let Some(BufferAssignment::NewBuffer(buffer)) = buffer else { return };
        if !is_top && popup.is_none() {
            buffer.release();
            return;
        }

        let mut pixels = Vec::new();
        let mut size = (0, 0);
        let _ = with_buffer_contents(&buffer, |ptr, len, d| {
            let stride = d.stride as usize;
            let (bw, bh) = (d.width as usize, d.height as usize);
            let data = unsafe { std::slice::from_raw_parts(ptr, len) };
            pixels.reserve(bw * bh * 4);
            for y in 0..bh {
                let start = d.offset as usize + y * stride;
                if start + bw * 4 <= data.len() {
                    pixels.extend_from_slice(&data[start..start + bw * 4]);
                }
            }
            size = (bw as i32, bh as i32);
        });
        buffer.release();

        if is_top {
            // the toplevel's pixels into base (clipped to the screen)
            let (w, h) = (self.width, self.height);
            let cw = size.0.min(w) as usize;
            for y in 0..size.1.min(h) as usize {
                let src = y * size.0 as usize * 4;
                let dst = y * w as usize * 4;
                if src + cw * 4 <= pixels.len() {
                    self.base[dst..dst + cw * 4].copy_from_slice(&pixels[src..src + cw * 4]);
                }
            }
            let mut rects: Vec<Rectangle<i32, smithay::utils::Logical>> = damage
                .iter()
                .map(|d| match d {
                    Damage::Surface(r) => *r,
                    Damage::Buffer(r) => Rectangle::new((r.loc.x, r.loc.y).into(), (r.size.w, r.size.h).into()),
                })
                .collect();
            if rects.is_empty() || rects.len() > 16 {
                rects = vec![Rectangle::new((0, 0).into(), (w, h).into())];
            }
            for r in rects {
                self.present(r);
            }
            self.flush();
        } else if let Some(i) = popup {
            let loc = self.popups[i].surface.with_pending_state(|s| s.geometry.loc);
            let old = self.popups[i].rect;
            self.popups[i].rect = Rectangle::new(loc, size.into());
            self.popups[i].pixels = pixels;
            let new = self.popups[i].rect;
            self.present(old);
            self.present(new);
            self.flush();
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
        surface.with_pending_state(|s| {
            s.size = Some((self.width, self.height).into());
            s.states.set(xdg_toplevel::State::Maximized);
            s.states.set(xdg_toplevel::State::Activated);
        });
        surface.send_configure();
        if let Some(keyboard) = self.seat.get_keyboard() {
            keyboard.set_focus(self, Some(surface.wl_surface().clone()), SERIAL_COUNTER.next_serial());
        }
        self.toplevel = Some(surface);
    }
    fn new_popup(&mut self, surface: PopupSurface, positioner: PositionerState) {
        let geometry = positioner.get_geometry();
        surface.with_pending_state(|s| s.geometry = geometry);
        let _ = surface.send_configure();
        self.popups.push(Popup { surface, rect: Rectangle::new(geometry.loc, (0, 0).into()), pixels: Vec::new() });
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
            self.present(gone.rect);   // what was under it shows again
            self.flush();
        }
    }
    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        if self.toplevel.as_ref() == Some(&surface) {
            self.toplevel = None;
        }
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
        let name = match image {
            CursorImageStatus::Named(icon) => icon.name().to_string(),
            CursorImageStatus::Hidden => "none".to_string(),
            _ => "default".to_string(),
        };
        self.emit(&format!("{{\"cursor\":\"{}\"}}", name));
    }
}
impl TabletSeatHandler for State {}
impl OutputHandler for State {}

delegate_compositor!(State);
delegate_shm!(State);
delegate_xdg_shell!(State);
delegate_seat!(State);
delegate_output!(State);
delegate_cursor_shape!(State);

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
    let mut seat_state = SeatState::new();
    let mut seat = seat_state.new_wl_seat(&dh, "seat0");
    seat.add_keyboard(XkbConfig { layout: &layout, ..Default::default() }, 400, 30).expect("keyboard (xkb layout)");
    seat.add_pointer();
    let outputs = OutputManagerState::new_with_xdg_output::<State>(&dh);
    let cursor_shape = CursorShapeManagerState::new::<State>(&dh);

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
        seat_state,
        seat,
        _outputs: outputs,
        _cursor_shape: cursor_shape,
        width,
        height,
        toplevel: None,
        base: vec![0u8; (width * height * 4) as usize],
        screen: vec![0u8; (width * height * 4) as usize],
        popups: Vec::new(),
        pending: Vec::new(),
        callbacks: Vec::new(),
        start: Instant::now(),
        out: std::io::BufWriter::with_capacity(1 << 20, std::io::stdout()),
    };
    state.emit(&format!("{{\"ready\":\"{}\"}}", SOCKET));

    loop {
        if event_loop.dispatch(Some(Duration::from_millis(16)), &mut state).is_err() {
            break;
        }
        let _ = state.dh.flush_clients();
    }
}
