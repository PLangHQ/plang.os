//! What plang-screen draws itself: each window's title bar and the address field.
//! Pixels are BGRA, premultiplied, like the clients'.

use crate::window::{Picture, Rect};

/// Title bar height.
pub const TITLE: i32 = 36;
/// How far outside a window its edges can be grabbed to resize it.
pub const EDGE: i32 = 6;

const SIDE: i32 = 34; // back, forward, address: square-ish buttons on the left
const CAPTION: i32 = 46; // minimize, maximize, close on the right
const TEXT_PX: f32 = 13.0;

/// The parts of a title bar.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Button {
    Back,
    Forward,
    Address,
    Title,
    Minimize,
    Maximize,
    Close,
}

impl Button {
    /// Which part of a title bar `width` wide is at `x` (from its left).
    pub fn at(x: i32, width: i32) -> Button {
        let left = 6;
        match x {
            x if x >= left && x < left + SIDE => Button::Back,
            x if x >= left + SIDE && x < left + 2 * SIDE => Button::Forward,
            x if x >= left + 2 * SIDE && x < left + 3 * SIDE => Button::Address,
            x if x >= width - CAPTION => Button::Close,
            x if x >= width - 2 * CAPTION => Button::Maximize,
            x if x >= width - 3 * CAPTION => Button::Minimize,
            _ => Button::Title,
        }
    }

    fn span(self, width: i32) -> (i32, i32) {
        let left = 6;
        match self {
            Button::Back => (left, SIDE),
            Button::Forward => (left + SIDE, SIDE),
            Button::Address => (left + 2 * SIDE, SIDE),
            Button::Minimize => (width - 3 * CAPTION, CAPTION),
            Button::Maximize => (width - 2 * CAPTION, CAPTION),
            Button::Close => (width - CAPTION, CAPTION),
            Button::Title => (0, 0),
        }
    }
}

/// A color, premultiplied BGRA.
#[derive(Clone, Copy)]
pub struct Color([f32; 4]);

impl Color {
    pub const fn rgba(r: u8, g: u8, b: u8, a: f32) -> Color {
        Color([b as f32 * a, g as f32 * a, r as f32 * a, 255.0 * a])
    }
}

// The desktop's palette (desktop.html): deep blue glass, light text, the orange accent.
const BAR_ACTIVE: Color = Color::rgba(0x1c, 0x26, 0x36, 1.0);
const BAR_INACTIVE: Color = Color::rgba(0x14, 0x1b, 0x27, 1.0);
const TEXT_ACTIVE: Color = Color::rgba(0xee, 0xf2, 0xf7, 1.0);
const TEXT_INACTIVE: Color = Color::rgba(0x8d, 0x9b, 0xb0, 1.0);
const HOVER: Color = Color::rgba(0xff, 0xff, 0xff, 0.10);
const CLOSE_HOVER: Color = Color::rgba(0xe5, 0x48, 0x4d, 1.0);
const FIELD: Color = Color::rgba(0x0f, 0x16, 0x21, 0.98);
const ACCENT: Color = Color::rgba(0xf2, 0xa3, 0x3a, 1.0);
const SELECTION: Color = Color::rgba(0x3a, 0x6e, 0xd8, 0.85);

/// Pixels to draw on.
pub struct Canvas {
    w: i32,
    h: i32,
    px: Vec<u8>,
}

impl Canvas {
    pub fn new(w: i32, h: i32) -> Canvas {
        Canvas { w: w.max(1), h: h.max(1), px: vec![0; (w.max(1) * h.max(1) * 4) as usize] }
    }

    /// `c` over the pixel at (x, y), `cover` of it (0..1).
    fn blend(&mut self, x: i32, y: i32, c: Color, cover: f32) {
        if x < 0 || y < 0 || x >= self.w || y >= self.h || cover <= 0.0 {
            return;
        }
        let i = ((y * self.w + x) * 4) as usize;
        let a = c.0[3] / 255.0 * cover.min(1.0);
        for k in 0..4 {
            let d = self.px[i + k] as f32;
            self.px[i + k] = (c.0[k] * cover.min(1.0) + d * (1.0 - a)).round().clamp(0.0, 255.0) as u8;
        }
    }

    pub fn fill(&mut self, x: i32, y: i32, w: i32, h: i32, c: Color) {
        for yy in y.max(0)..(y + h).min(self.h) {
            for xx in x.max(0)..(x + w).min(self.w) {
                self.blend(xx, yy, c, 1.0);
            }
        }
    }

    /// A filled rectangle with round corners (radius r), smooth edges.
    pub fn round(&mut self, x: i32, y: i32, w: i32, h: i32, r: f32, c: Color, top_only: bool) {
        for yy in y.max(0)..(y + h).min(self.h) {
            for xx in x.max(0)..(x + w).min(self.w) {
                let (px, py) = (xx as f32 + 0.5, yy as f32 + 0.5);
                let (l, t, rr, b) = (x as f32 + r, y as f32 + r, (x + w) as f32 - r, (y + h) as f32 - r);
                let cx = px.clamp(l, rr);
                let cy = if top_only { py.max(t) } else { py.clamp(t, b) };
                let d = ((px - cx).powi(2) + (py - cy).powi(2)).sqrt();
                self.blend(xx, yy, c, (r - d + 0.5).clamp(0.0, 1.0));
            }
        }
    }

    /// A line from (x0, y0) to (x1, y1), `width` wide, smooth.
    pub fn line(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, c: Color) {
        let (minx, maxx) = (x0.min(x1) - width, x0.max(x1) + width);
        let (miny, maxy) = (y0.min(y1) - width, y0.max(y1) + width);
        let (dx, dy) = (x1 - x0, y1 - y0);
        let len2 = (dx * dx + dy * dy).max(1e-6);
        for yy in miny.floor() as i32..=maxy.ceil() as i32 {
            for xx in minx.floor() as i32..=maxx.ceil() as i32 {
                let (px, py) = (xx as f32 + 0.5, yy as f32 + 0.5);
                let t = (((px - x0) * dx + (py - y0) * dy) / len2).clamp(0.0, 1.0);
                let d = ((px - x0 - t * dx).powi(2) + (py - y0 - t * dy).powi(2)).sqrt();
                self.blend(xx, yy, c, (width / 2.0 - d + 0.5).clamp(0.0, 1.0));
            }
        }
    }

    /// A circle outline around (cx, cy), radius r.
    pub fn ring(&mut self, cx: f32, cy: f32, r: f32, width: f32, c: Color) {
        for yy in (cy - r - width).floor() as i32..=(cy + r + width).ceil() as i32 {
            for xx in (cx - r - width).floor() as i32..=(cx + r + width).ceil() as i32 {
                let d = ((xx as f32 + 0.5 - cx).powi(2) + (yy as f32 + 0.5 - cy).powi(2)).sqrt();
                self.blend(xx, yy, c, (width / 2.0 - (d - r).abs() + 0.5).clamp(0.0, 1.0));
            }
        }
    }

    /// An ellipse outline around (cx, cy), radii rx and ry.
    pub fn ellipse(&mut self, cx: f32, cy: f32, rx: f32, ry: f32, width: f32, c: Color) {
        for yy in (cy - ry - width).floor() as i32..=(cy + ry + width).ceil() as i32 {
            for xx in (cx - rx - width).floor() as i32..=(cx + rx + width).ceil() as i32 {
                let (dx, dy) = (xx as f32 + 0.5 - cx, yy as f32 + 0.5 - cy);
                // distance to the outline, first order: (k - 1) / |∇k|, k the ellipse's own radius
                let k = ((dx / rx).powi(2) + (dy / ry).powi(2)).sqrt().max(1e-3);
                let grad = ((dx / (rx * rx)).powi(2) + (dy / (ry * ry)).powi(2)).sqrt() / k;
                let d = (k - 1.0) / grad.max(1e-3);
                self.blend(xx, yy, c, (width / 2.0 - d.abs() + 0.5).clamp(0.0, 1.0));
            }
        }
    }

    /// Text from `x` on the line whose middle is `mid`, cut with … before `max_x`; returns where
    /// each character starts (and where the last one ends).
    pub fn text(&mut self, font: Option<&fontdue::Font>, text: &str, x: f32, mid: f32, max_x: f32, c: Color) -> Vec<f32> {
        let Some(font) = font else { return vec![x] };
        let lines = font.horizontal_line_metrics(TEXT_PX);
        let (ascent, descent) = lines.map(|l| (l.ascent, l.descent)).unwrap_or((TEXT_PX * 0.8, -TEXT_PX * 0.2));
        let baseline = (mid + (ascent + descent) / 2.0).round();
        let width: f32 = text.chars().map(|ch| font.metrics(ch, TEXT_PX).advance_width).sum();
        let ellipsis = font.metrics('…', TEXT_PX).advance_width;
        let cut = x + width > max_x;
        let mut pen = x;
        let mut starts = vec![];
        for ch in text.chars() {
            let advance = font.metrics(ch, TEXT_PX).advance_width;
            if cut && pen + advance > max_x - ellipsis {
                self.glyph(font, '…', pen, baseline, c);
                starts.push(pen);
                return starts;
            }
            starts.push(pen);
            self.glyph(font, ch, pen, baseline, c);
            pen += advance;
        }
        starts.push(pen);
        starts
    }

    fn glyph(&mut self, font: &fontdue::Font, ch: char, pen: f32, baseline: f32, c: Color) {
        let (m, cover) = font.rasterize(ch, TEXT_PX);
        let left = pen.round() as i32 + m.xmin;
        let top = baseline as i32 - m.ymin - m.height as i32;
        for gy in 0..m.height {
            for gx in 0..m.width {
                let a = cover[gy * m.width + gx] as f32 / 255.0;
                self.blend(left + gx as i32, top + gy as i32, c, a);
            }
        }
    }

    pub fn picture(self, at: (i32, i32)) -> Picture {
        Picture { rect: Rect::new(at.into(), (self.w, self.h).into()), pixels: self.px, opaque: false }
    }
}

/// A window's title bar, `width` wide: back, forward, address; the title; minimize, maximize
/// (restore when maximized), close. `hover` is the part under the pointer.
pub fn title_bar(font: Option<&fontdue::Font>, width: i32, title: &str, active: bool, maximized: bool, hover: Option<Button>) -> Canvas {
    let mut c = Canvas::new(width, TITLE);
    let bar = if active { BAR_ACTIVE } else { BAR_INACTIVE };
    let ink = if active { TEXT_ACTIVE } else { TEXT_INACTIVE };
    c.round(0, 0, width, TITLE, if maximized { 0.0 } else { 8.0 }, bar, true);
    if let Some(b) = hover.filter(|b| *b != Button::Title) {
        let (x, w) = b.span(width);
        if b == Button::Close {
            c.fill(x, 0, w, TITLE, CLOSE_HOVER);
        } else if matches!(b, Button::Minimize | Button::Maximize) {
            c.fill(x, 0, w, TITLE, HOVER);
        } else {
            c.round(x + 2, 5, w - 4, TITLE - 10, 6.0, HOVER, false);
        }
    }
    let mid = TITLE as f32 / 2.0;
    let stroke = 1.4;
    // back ‹ and forward ›
    let (bx, _) = Button::Back.span(width);
    let cx = (bx + SIDE / 2) as f32;
    c.line(cx + 2.5, mid - 5.0, cx - 2.5, mid, stroke, ink);
    c.line(cx - 2.5, mid, cx + 2.5, mid + 5.0, stroke, ink);
    let (fx, _) = Button::Forward.span(width);
    let cx = (fx + SIDE / 2) as f32;
    c.line(cx - 2.5, mid - 5.0, cx + 2.5, mid, stroke, ink);
    c.line(cx + 2.5, mid, cx - 2.5, mid + 5.0, stroke, ink);
    // address: a globe
    let (ax, _) = Button::Address.span(width);
    let cx = (ax + SIDE / 2) as f32;
    c.ring(cx, mid, 7.0, 1.2, ink);
    c.line(cx - 7.0, mid, cx + 7.0, mid, 1.0, ink);
    c.ellipse(cx, mid, 3.2, 7.0, 1.0, ink);
    // the title, between the left buttons and the caption buttons
    let text_x = (6 + 3 * SIDE + 10) as f32;
    c.text(font, title, text_x, mid, (width - 3 * CAPTION - 12) as f32, ink);
    // minimize —, maximize □ (restore ⧉), close ×
    let (mx, _) = Button::Minimize.span(width);
    let cx = (mx + CAPTION / 2) as f32;
    c.line(cx - 5.0, mid + 0.5, cx + 5.0, mid + 0.5, 1.0, ink);
    let (xx, _) = Button::Maximize.span(width);
    let cx = (xx + CAPTION / 2) as f32;
    // 1 px lines sit on pixel centers (.5): crisp, not smeared over two pixels
    if maximized {
        square(&mut c, cx - 1.5, mid + 1.5, 8.0, ink);
        c.line(cx + 0.5, mid - 4.5, cx + 6.5, mid - 4.5, 1.0, ink);
        c.line(cx + 6.5, mid - 4.5, cx + 6.5, mid + 1.5, 1.0, ink);
    } else {
        square(&mut c, cx + 0.5, mid + 0.5, 10.0, ink);
    }
    let (kx, _) = Button::Close.span(width);
    let cx = (kx + CAPTION / 2) as f32;
    let close_ink = if hover == Some(Button::Close) { TEXT_ACTIVE } else { ink };
    c.line(cx - 5.0, mid - 5.0, cx + 5.0, mid + 5.0, 1.1, close_ink);
    c.line(cx + 5.0, mid - 5.0, cx - 5.0, mid + 5.0, 1.1, close_ink);
    c
}

fn square(c: &mut Canvas, cx: f32, cy: f32, size: f32, ink: Color) {
    let (l, t, r, b) = (cx - size / 2.0, cy - size / 2.0, cx + size / 2.0, cy + size / 2.0);
    c.line(l, t, r, t, 1.0, ink);
    c.line(r, t, r, b, 1.0, ink);
    c.line(r, b, l, b, 1.0, ink);
    c.line(l, b, l, t, 1.0, ink);
}

/// The address field that drops down under a title bar: the text, the caret, the selection.
pub struct Address {
    pub id: u32,
    pub text: String,
    pub caret: usize,     // in characters
    pub selected: bool,   // everything selected (as it opens: typing replaces it)
}

impl Address {
    pub const HEIGHT: i32 = 40;

    pub fn new(id: u32, url: &str) -> Address {
        Address { id, text: url.to_string(), caret: url.chars().count(), selected: true }
    }

    fn cut(&mut self) {
        if self.selected {
            self.text.clear();
            self.caret = 0;
            self.selected = false;
        }
    }

    fn byte(&self, chars: usize) -> usize {
        self.text.char_indices().nth(chars).map(|(i, _)| i).unwrap_or(self.text.len())
    }

    pub fn typed(&mut self, s: &str) {
        self.cut();
        let at = self.byte(self.caret);
        self.text.insert_str(at, s);
        self.caret += s.chars().count();
    }

    pub fn backspace(&mut self) {
        if self.selected {
            return self.cut();
        }
        if self.caret > 0 {
            let at = self.byte(self.caret - 1);
            self.text.remove(at);
            self.caret -= 1;
        }
    }

    pub fn delete(&mut self) {
        if self.selected {
            return self.cut();
        }
        if self.caret < self.text.chars().count() {
            let at = self.byte(self.caret);
            self.text.remove(at);
        }
    }

    pub fn step(&mut self, to: isize) {
        let n = self.text.chars().count() as isize;
        self.caret = if self.selected && to < 0 { 0 } else if self.selected { n as usize } else { (self.caret as isize + to).clamp(0, n) as usize };
        self.selected = false;
    }

    pub fn home(&mut self, end: bool) {
        self.caret = if end { self.text.chars().count() } else { 0 };
        self.selected = false;
    }

    pub fn draw(&self, font: Option<&fontdue::Font>, width: i32) -> Canvas {
        let (w, h) = (width, Address::HEIGHT);
        let mut c = Canvas::new(w + 8, h + 8);
        c.round(4, 6, w, h, 10.0, Color::rgba(0, 0, 0, 0.35), false); // shadow
        c.round(4, 4, w, h, 10.0, ACCENT, false);
        c.round(5, 5, w - 2, h - 2, 9.0, FIELD, false);
        let mid = 4.0 + h as f32 / 2.0;
        let x = 18.0;
        if self.selected && !self.text.is_empty() {
            let mut probe = Canvas::new(1, 1);
            let ends = probe.text(font, &self.text, x, mid, (w - 16) as f32, TEXT_ACTIVE);
            let end = ends.last().copied().unwrap_or(x);
            c.round(x as i32 - 2, 13, (end - x) as i32 + 4, h - 18, 3.0, SELECTION, false);
        }
        let starts = c.text(font, &self.text, x, mid, (w - 16) as f32, TEXT_ACTIVE);
        if !self.selected {
            let cx = starts.get(self.caret).copied().unwrap_or(x);
            c.line(cx, mid - 8.0, cx, mid + 8.0, 1.2, ACCENT);
        }
        c
    }
}
