//! What's on the screen: pictures (a client's pixels at a place), windows, and the stack of them.

use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point, Rectangle, Size};
use smithay::wayland::compositor::with_states;
use smithay::wayland::shell::xdg::{PopupSurface, SurfaceCachedState, ToplevelSurface, XdgToplevelSurfaceData};

use crate::frame::{Button, EDGE, TITLE};

pub type Rect = Rectangle<i32, Logical>;

/// A client's pixels (BGRA, premultiplied) and where they are on the screen.
#[derive(Default)]
pub struct Picture {
    pub rect: Rect,
    pub pixels: Vec<u8>,
    pub opaque: bool, // XRGB: the alpha byte means nothing
}

impl Picture {
    pub fn is_empty(&self) -> bool {
        self.pixels.is_empty()
    }

    /// This picture over `line`, the screen's row `y` from column `x0`. Translucent pixels
    /// (Chromium's window shadows) blend with what's under them.
    pub fn draw(&self, y: i32, x0: i32, line: &mut [u8]) {
        let r = self.rect;
        if y < r.loc.y || y >= r.loc.y + r.size.h {
            return;
        }
        let x1 = x0 + (line.len() / 4) as i32;
        let sx = x0.max(r.loc.x);
        let ex = x1.min(r.loc.x + r.size.w);
        if ex <= sx {
            return;
        }
        let src = ((y - r.loc.y) * r.size.w + (sx - r.loc.x)) as usize * 4;
        let dst = (sx - x0) as usize * 4;
        let n = (ex - sx) as usize * 4;
        if src + n > self.pixels.len() {
            return;
        }
        let from = &self.pixels[src..src + n];
        let to = &mut line[dst..dst + n];
        if self.opaque {
            to.copy_from_slice(from);
            return;
        }
        for (s, d) in from.chunks_exact(4).zip(to.chunks_exact_mut(4)) {
            match s[3] {
                255 => d.copy_from_slice(s),
                0 => {}
                a => {
                    let keep = 255 - a as u32;
                    for c in 0..4 {
                        d[c] = (s[c] as u32 + d[c] as u32 * keep / 255).min(255) as u8;
                    }
                }
            }
        }
    }
}

/// The part of a surface that is the window, inside its buffer: Chromium draws shadows around it.
pub fn geometry(surface: &WlSurface) -> Option<Rect> {
    with_states(surface, |states| states.cached_state.get::<SurfaceCachedState>().current().geometry)
}

/// What the pointer is on.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Part {
    Content,
    Bar(Button),
    Edge(u32),
}

impl Part {
    /// The pointer over this part, by its CSS name (the host shows it).
    pub fn cursor(self) -> &'static str {
        match self {
            Part::Edge(1) | Part::Edge(2) => "ns-resize",
            Part::Edge(4) | Part::Edge(8) => "ew-resize",
            Part::Edge(5) | Part::Edge(10) => "nwse-resize",
            Part::Edge(6) | Part::Edge(9) => "nesw-resize",
            _ => "default",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Shown {
    Normal,
    Maximized,
    Minimized,
}

pub struct Window {
    pub id: u32,
    pub surface: ToplevelSurface,
    pub desktop: bool,
    pub at: Point<i32, Logical>,     // where the window (without shadows) is on the screen
    pub offset: Point<i32, Logical>, // where the window starts inside its buffer
    pub size: Size<i32, Logical>,    // the window's size, without shadows
    pub picture: Picture,
    pub bar: Picture,   // its title bar, drawn by plang-screen (not for the desktop)
    pub url: String,    // the page it shows (from PLang), for the address field
    pub shown: Shown,
    pub restore: Rect, // where it was before it was maximized
    pub was: Shown,    // how it showed before it was minimized
}

impl Window {
    pub fn new(id: u32, surface: ToplevelSurface, desktop: bool, at: Point<i32, Logical>, size: Size<i32, Logical>) -> Self {
        Window { id, surface, desktop, at, offset: (0, 0).into(), size, picture: Picture::default(), bar: Picture::default(), url: String::new(), shown: Shown::Normal, restore: Rect::new(at, size), was: Shown::Normal }
    }

    pub fn visible(&self) -> bool {
        self.shown != Shown::Minimized && !self.picture.is_empty()
    }

    /// The window on the screen, without its shadows.
    pub fn frame(&self) -> Rect {
        Rect::new(self.at, self.size)
    }

    /// The window with its title bar.
    pub fn outer(&self) -> Rect {
        if self.desktop {
            return self.picture.rect;
        }
        Rect::new((self.at.x, self.at.y - TITLE).into(), (self.size.w, self.size.h + TITLE).into())
    }

    /// Puts the picture and the title bar where the window is.
    pub fn place(&mut self) {
        self.picture.rect.loc = self.at - self.offset;
        self.bar.rect.loc = (self.at.x, self.at.y - TITLE).into();
    }

    /// What of this window is at (x, y): its page, a part of its title bar, or an edge
    /// (top 1, bottom 2, left 4, right 8, as xdg_toplevel's resize edges).
    pub fn part(&self, x: i32, y: i32) -> Option<Part> {
        if !self.visible() {
            return None;
        }
        if self.desktop || self.picture.rect.contains((x, y)) {
            return self.picture.rect.contains((x, y)).then_some(Part::Content);
        }
        let outer = self.outer();
        if outer.contains((x, y)) {
            return (y < self.at.y).then(|| Part::Bar(Button::at(x - outer.loc.x, outer.size.w))).or(Some(Part::Content));
        }
        if self.shown == Shown::Maximized {
            return None;
        }
        let grow = Rect::new((outer.loc.x - EDGE, outer.loc.y - EDGE).into(), (outer.size.w + 2 * EDGE, outer.size.h + 2 * EDGE).into());
        if !grow.contains((x, y)) {
            return None;
        }
        let mut edges = 0;
        if y < outer.loc.y {
            edges |= 1;
        }
        if y >= outer.loc.y + outer.size.h {
            edges |= 2;
        }
        if x < outer.loc.x {
            edges |= 4;
        }
        if x >= outer.loc.x + outer.size.w {
            edges |= 8;
        }
        Some(Part::Edge(edges))
    }

    pub fn wl(&self) -> &WlSurface {
        self.surface.wl_surface()
    }

    pub fn title(&self) -> String {
        self.role(|r| r.title.clone())
    }

    pub fn app(&self) -> String {
        self.role(|r| r.app_id.clone())
    }

    fn role(&self, read: impl Fn(&smithay::wayland::shell::xdg::XdgToplevelSurfaceRoleAttributes) -> Option<String>) -> String {
        with_states(self.wl(), |states| {
            states.data_map.get::<XdgToplevelSurfaceData>().and_then(|d| d.lock().ok().and_then(|r| read(&r)))
        })
        .unwrap_or_default()
    }

    /// Asks the client for a size and states; sent only if something changed.
    pub fn configure(&self, size: Option<Size<i32, Logical>>, states: &[(xdg_toplevel::State, bool)]) {
        self.surface.with_pending_state(|s| {
            if size.is_some() {
                s.size = size;
            }
            for (state, on) in states {
                if *on {
                    s.states.set(*state);
                } else {
                    s.states.unset(*state);
                }
            }
        });
        if self.surface.is_initial_configure_sent() {
            self.surface.send_pending_configure();
        } else {
            self.surface.send_configure();
        }
    }
}

/// The windows, bottom to top. The desktop stays at the bottom.
#[derive(Default)]
pub struct Windows {
    list: Vec<Window>,
    next: u32,
}

impl Windows {
    pub fn add(&mut self, surface: ToplevelSurface, at: Point<i32, Logical>, size: Size<i32, Logical>) -> usize {
        let desktop = self.next == 0; // the first window is the desktop: the one the screen started with
        self.next += 1;
        self.list.push(Window::new(if desktop { 0 } else { self.next - 1 }, surface, desktop, at, size));
        self.list.len() - 1
    }

    pub fn remove(&mut self, i: usize) -> Window {
        self.list.remove(i)
    }

    pub fn of(&self, surface: &WlSurface) -> Option<usize> {
        self.list.iter().position(|w| w.wl() == surface)
    }

    pub fn by_id(&self, id: u32) -> Option<usize> {
        self.list.iter().position(|w| w.id == id)
    }

    pub fn get(&self, i: usize) -> &Window {
        &self.list[i]
    }

    pub fn get_mut(&mut self, i: usize) -> &mut Window {
        &mut self.list[i]
    }

    pub fn iter(&self) -> impl Iterator<Item = &Window> {
        self.list.iter()
    }

    pub fn count(&self) -> usize {
        self.list.iter().filter(|w| !w.desktop).count()
    }

    pub fn desktop(&self) -> Option<&Window> {
        self.list.iter().find(|w| w.desktop)
    }

    /// Moves window `i` to the top; returns where it is now.
    pub fn raise(&mut self, i: usize) -> usize {
        if self.list[i].desktop {
            return i;
        }
        let w = self.list.remove(i);
        self.list.push(w);
        self.list.len() - 1
    }

    /// The topmost window that shows, else the desktop.
    pub fn top(&self) -> Option<usize> {
        self.list.iter().rposition(|w| !w.desktop && w.shown != Shown::Minimized).or_else(|| self.list.iter().position(|w| w.desktop))
    }

    /// The topmost window at (x, y), and what of it is there.
    pub fn hit(&self, x: i32, y: i32) -> Option<(usize, Part)> {
        self.list.iter().enumerate().rev().find_map(|(i, w)| w.part(x, y).map(|p| (i, p)))
    }
}

pub struct Popup {
    pub surface: PopupSurface,
    pub picture: Picture,
}
