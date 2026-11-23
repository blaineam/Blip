//! The notification-area presence. Windows tray icons are a single small square, so the Mac's
//! menu-bar strip becomes one of three styles: mini bars (one per metric, in one icon), one icon
//! per metric showing its number, or the logo alone. Icons are rasterised here at 32 px.

use blip_core::model::Snapshot;
use blip_core::settings::{Settings, TrayStyle};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

use crate::theme::{self, Category};

pub const SIZE: usize = 32;

pub struct Canvas {
    pub px: Vec<u8>,
}

impl Canvas {
    pub fn new() -> Self {
        Self {
            px: vec![0; SIZE * SIZE * 4],
        }
    }

    fn blend(&mut self, x: i32, y: i32, c: [u8; 4], cover: f32) {
        if x < 0 || y < 0 || x >= SIZE as i32 || y >= SIZE as i32 || cover <= 0.0 {
            return;
        }
        let i = (y as usize * SIZE + x as usize) * 4;
        let a = c[3] as f32 / 255.0 * cover.min(1.0);
        let da = self.px[i + 3] as f32 / 255.0;
        let oa = a + da * (1.0 - a);
        if oa <= 0.0 {
            return;
        }
        for k in 0..3 {
            let v = (c[k] as f32 * a + self.px[i + k] as f32 * da * (1.0 - a)) / oa;
            self.px[i + k] = v.round() as u8;
        }
        self.px[i + 3] = (oa * 255.0).round() as u8;
    }

    /// Anti-aliased rounded rectangle.
    pub fn round_rect(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, r: f32, c: [u8; 4]) {
        let r = r.min((x1 - x0) / 2.0).min((y1 - y0) / 2.0);
        for y in y0.floor() as i32..y1.ceil() as i32 {
            for x in x0.floor() as i32..x1.ceil() as i32 {
                let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
                let qx = (px - x0.max(px.min(x1)).min(x1)).abs();
                let _ = qx;
                let cx = px.clamp(x0 + r, x1 - r);
                let cy = py.clamp(y0 + r, y1 - r);
                let d = ((px - cx).powi(2) + (py - cy).powi(2)).sqrt() - r;
                let edge = (0.5 - d).clamp(0.0, 1.0);
                let inside_x = (px - x0).min(x1 - px) + 0.5;
                let inside_y = (py - y0).min(y1 - py) + 0.5;
                let cover = edge.min(inside_x.clamp(0.0, 1.0)).min(inside_y.clamp(0.0, 1.0));
                self.blend(x, y, c, cover);
            }
        }
    }

    pub fn circle(&mut self, cx: f32, cy: f32, r: f32, c: [u8; 4]) {
        for y in (cy - r - 1.0) as i32..=(cy + r + 1.0) as i32 {
            for x in (cx - r - 1.0) as i32..=(cx + r + 1.0) as i32 {
                let d = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
                self.blend(x, y, c, (r + 0.5 - d).clamp(0.0, 1.0));
            }
        }
    }

    /// 3×5 pixel digits at integer `scale`, centred horizontally.
    pub fn number(&mut self, text: &str, top: i32, scale: i32, c: [u8; 4]) {
        let glyphs: Vec<[u8; 5]> = text.chars().filter_map(glyph).collect();
        let w = glyphs.len() as i32 * 3 * scale + (glyphs.len() as i32 - 1).max(0) * scale;
        let mut x = (SIZE as i32 - w) / 2;
        for g in glyphs {
            for (row, bits) in g.iter().enumerate() {
                for col in 0..3 {
                    if bits & (0b100 >> col) != 0 {
                        for dy in 0..scale {
                            for dx in 0..scale {
                                self.blend(x + col * scale + dx, top + row as i32 * scale + dy, c, 1.0);
                            }
                        }
                    }
                }
            }
            x += 4 * scale;
        }
    }

    pub fn icon(self) -> Option<Icon> {
        Icon::from_rgba(self.px, SIZE as u32, SIZE as u32).ok()
    }
}

fn glyph(c: char) -> Option<[u8; 5]> {
    Some(match c {
        '0' => [0b111, 0b101, 0b101, 0b101, 0b111],
        '1' => [0b010, 0b110, 0b010, 0b010, 0b111],
        '2' => [0b111, 0b001, 0b111, 0b100, 0b111],
        '3' => [0b111, 0b001, 0b111, 0b001, 0b111],
        '4' => [0b101, 0b101, 0b111, 0b001, 0b001],
        '5' => [0b111, 0b100, 0b111, 0b001, 0b111],
        '6' => [0b111, 0b100, 0b111, 0b101, 0b111],
        '7' => [0b111, 0b001, 0b010, 0b010, 0b010],
        '8' => [0b111, 0b101, 0b111, 0b101, 0b111],
        '9' => [0b111, 0b101, 0b111, 0b001, 0b111],
        _ => return None,
    })
}

fn rgba(c: eframe::egui::Color32) -> [u8; 4] {
    [c.r(), c.g(), c.b(), 255]
}

pub struct Metric {
    pub id: &'static str,
    pub category: Category,
    pub pct: f64,
}

pub fn metrics(s: &Snapshot, set: &Settings) -> Vec<Metric> {
    let mut v = Vec::new();
    if set.show_cpu {
        v.push(Metric {
            id: "cpu",
            category: Category::Cpu,
            pct: s.cpu.total,
        });
    }
    if set.show_memory {
        v.push(Metric {
            id: "memory",
            category: Category::Memory,
            pct: s.memory.usage_pct(),
        });
    }
    if set.show_disk {
        v.push(Metric {
            id: "disk",
            category: Category::Disk,
            pct: s.disk.system_volume().map_or(0.0, |v| v.usage_pct()),
        });
    }
    if set.show_gpu && s.gpu.available {
        v.push(Metric {
            id: "gpu",
            category: Category::Gpu,
            pct: s.gpu.utilization,
        });
    }
    v
}

fn color_for(m: &Metric, set: &Settings, light_taskbar: bool) -> [u8; 4] {
    if set.colorize_utilization {
        rgba(theme::load_color(m.pct))
    } else {
        rgba(theme::accent(
            m.category,
            &set.accent_color_override,
            !light_taskbar,
        ))
    }
}

fn ink(light_taskbar: bool, alpha: u8) -> [u8; 4] {
    if light_taskbar {
        [20, 20, 20, alpha]
    } else {
        [255, 255, 255, alpha]
    }
}

/// The combined "bars" icon.
pub fn render_bars(s: &Snapshot, set: &Settings, light_taskbar: bool) -> Canvas {
    let mut c = Canvas::new();
    let ms = metrics(s, set);
    let left = if set.show_network_dot { 8.0 } else { 2.0 };
    if set.show_network_dot {
        let dot = if s.network.connected {
            rgba(theme::GREEN)
        } else {
            rgba(theme::RED)
        };
        c.circle(3.5, 16.0, 3.0, dot);
    }
    if ms.is_empty() {
        return render_logo(light_taskbar);
    }
    let n = ms.len() as f32;
    let gap = 3.0;
    let h = ((30.0 - gap * (n - 1.0)) / n).min(8.0);
    let total = h * n + gap * (n - 1.0);
    let mut y = (SIZE as f32 - total) / 2.0;
    for m in &ms {
        c.round_rect(left, y, 30.0, y + h, h / 2.0, ink(light_taskbar, 70));
        let w = ((30.0 - left) * (m.pct / 100.0).clamp(0.0, 1.0) as f32).max(h);
        c.round_rect(
            left,
            y,
            left + w,
            y + h,
            h / 2.0,
            color_for(m, set, light_taskbar),
        );
        y += h + gap;
    }
    c
}

/// One metric as its number with a load bar underneath.
pub fn render_number(m: &Metric, set: &Settings, light_taskbar: bool) -> Canvas {
    let mut c = Canvas::new();
    let v = m.pct.round().clamp(0.0, 100.0) as u32;
    let text = v.to_string();
    if text.len() >= 3 {
        c.number(&text, 3, 3, ink(light_taskbar, 255));
    } else {
        c.number(&text, 1, 4, ink(light_taskbar, 255));
    }
    c.round_rect(2.0, 25.0, 30.0, 30.0, 2.5, ink(light_taskbar, 70));
    let w = (28.0 * (m.pct / 100.0).clamp(0.0, 1.0) as f32).max(5.0);
    c.round_rect(2.0, 25.0, 2.0 + w, 30.0, 2.5, color_for(m, set, light_taskbar));
    c
}

/// The Blip mark at tray size: the app icon's navy tile, cyan "blip" and three bars.
pub fn render_logo(_light_taskbar: bool) -> Canvas {
    let mut c = Canvas::new();
    c.round_rect(0.5, 0.5, 31.5, 31.5, 7.0, [16, 25, 54, 255]);
    c.circle(16.0, 9.5, 7.0, [77, 229, 255, 40]);
    c.circle(16.0, 9.5, 4.0, [77, 229, 255, 255]);
    let bars = [
        ([10, 132, 255, 255], 0.72),
        ([48, 209, 89, 255], 0.5),
        ([255, 159, 10, 255], 0.3),
    ];
    for (i, (col, f)) in bars.iter().enumerate() {
        let y = 17.5 + i as f32 * 4.8;
        c.round_rect(5.0, y, 27.0, y + 3.2, 1.6, [col[0], col[1], col[2], 70]);
        c.round_rect(5.0, y, 5.0 + 22.0 * f, y + 3.2, 1.6, *col);
    }
    c
}

pub fn tooltip(s: &Snapshot) -> String {
    use blip_core::{fmt, t};
    let mut parts = vec![
        format!("{} {}", t("CPU"), fmt::percent(s.cpu.total)),
        format!("{} {}", t("Memory"), fmt::percent(s.memory.usage_pct())),
    ];
    if let Some(v) = s.disk.system_volume() {
        parts.push(format!("{} {}", t("Disk"), fmt::percent(v.usage_pct())));
    }
    parts.push(format!(
        "↓{} ↑{}",
        fmt::short_speed(s.network.down_bps),
        fmt::short_speed(s.network.up_bps)
    ));
    format!("Blip — {}", parts.join(" · "))
}

/// Owns the tray icon(s) and re-renders them when the picture changes.
pub struct Tray {
    icons: Vec<(String, TrayIcon)>,
    last: Vec<(String, Vec<u8>)>,
    style: Option<TrayStyle>,
    last_tip: String,
}

impl Tray {
    pub fn new() -> Self {
        Self {
            icons: Vec::new(),
            last: Vec::new(),
            style: None,
            last_tip: String::new(),
        }
    }

    pub fn update(&mut self, s: &Snapshot, set: &Settings, light_taskbar: bool) {
        let mut wanted: Vec<(String, Canvas)> = match set.tray_style {
            TrayStyle::Bars => vec![("blip".into(), render_bars(s, set, light_taskbar))],
            TrayStyle::Logo => vec![("blip".into(), render_logo(light_taskbar))],
            TrayStyle::Numbers => {
                let ms = metrics(s, set);
                if ms.is_empty() {
                    vec![("blip".into(), render_logo(light_taskbar))]
                } else {
                    ms.iter()
                        .map(|m| (format!("blip-{}", m.id), render_number(m, set, light_taskbar)))
                        .collect()
                }
            }
        };
        let ids: Vec<String> = wanted.iter().map(|(id, _)| id.clone()).collect();
        let current: Vec<String> = self.icons.iter().map(|(id, _)| id.clone()).collect();
        if ids != current || self.style != Some(set.tray_style) {
            // Rebuild (style or metric set changed). Dropping a TrayIcon removes it.
            self.icons.clear();
            self.last.clear();
            for (id, canvas) in wanted.drain(..) {
                let px = canvas.px.clone();
                if let Some(icon) = canvas.icon() {
                    if let Ok(t) = TrayIconBuilder::new()
                        .with_id(id.clone())
                        .with_icon(icon)
                        .with_tooltip("Blip")
                        .build()
                    {
                        self.icons.push((id.clone(), t));
                        self.last.push((id, px));
                    }
                }
            }
            self.style = Some(set.tray_style);
            self.last_tip.clear();
        } else {
            for (id, canvas) in wanted {
                let changed = self
                    .last
                    .iter()
                    .find(|(i, _)| *i == id)
                    .is_none_or(|(_, px)| *px != canvas.px);
                if changed {
                    let px = canvas.px.clone();
                    if let (Some(icon), Some((_, t))) =
                        (canvas.icon(), self.icons.iter().find(|(i, _)| *i == id))
                    {
                        let _ = t.set_icon(Some(icon));
                    }
                    if let Some(slot) = self.last.iter_mut().find(|(i, _)| *i == id) {
                        slot.1 = px;
                    }
                }
            }
        }
        let tip = tooltip(s);
        if tip != self.last_tip {
            for (_, t) in &self.icons {
                let _ = t.set_tooltip(Some(&tip));
            }
            self.last_tip = tip;
        }
    }

    /// Screen rect (physical px) of the first icon — where the popover anchors.
    pub fn anchor(&self) -> Option<tray_icon::Rect> {
        self.icons.first().and_then(|(_, t)| t.rect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_every_style() {
        let mut s = Snapshot::default();
        s.cpu.total = 100.0;
        s.memory.total = 10;
        s.memory.used = 5;
        let set = Settings::default();
        assert!(render_bars(&s, &set, false).px.iter().any(|b| *b != 0));
        let m = Metric {
            id: "cpu",
            category: Category::Cpu,
            pct: 100.0,
        };
        assert!(render_number(&m, &set, true).px.iter().any(|b| *b != 0));
        assert!(render_logo(false).px.iter().any(|b| *b != 0));
    }
}
