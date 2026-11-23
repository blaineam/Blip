//! Look and feel: fonts loaded from the OS (Segoe UI + a CJK fallback on Windows — nothing
//! bundled), the Mac's category colours, and a small vector icon set drawn with the painter so
//! it renders the same on every platform and at every DPI.

use eframe::egui::{self, Color32, FontData, FontDefinitions, FontFamily, Pos2, Rect, Stroke, Vec2};
use eframe::epaint::{PathShape, PathStroke};

use blip_core::Icon;

pub fn install_fonts(ctx: &egui::Context) {
    let sys = blip_platform::system_fonts();
    let mut fonts = FontDefinitions::default();
    let mut add = |name: &str, path: &Option<std::path::PathBuf>, family: FontFamily, front: bool| {
        let Some(p) = path else { return };
        let Ok(bytes) = std::fs::read(p) else { return };
        fonts
            .font_data
            .insert(name.into(), FontData::from_owned(bytes).into());
        let list = fonts.families.entry(family).or_default();
        if front {
            list.insert(0, name.into());
        } else {
            list.push(name.into());
        }
    };
    add("ui", &sys.ui, FontFamily::Proportional, true);
    add("mono", &sys.mono, FontFamily::Monospace, true);
    if let Some(b) = &sys.ui_bold {
        if let Ok(bytes) = std::fs::read(b) {
            fonts
                .font_data
                .insert("bold".into(), FontData::from_owned(bytes).into());
            fonts
                .families
                .insert(FontFamily::Name("bold".into()), vec!["bold".into(), "ui".into()]);
        }
    }
    for (i, p) in sys.cjk.iter().enumerate() {
        if let Ok(bytes) = std::fs::read(p) {
            let name = format!("cjk{i}");
            fonts
                .font_data
                .insert(name.clone(), FontData::from_owned(bytes).into());
            for fam in [FontFamily::Proportional, FontFamily::Monospace] {
                fonts.families.entry(fam).or_default().push(name.clone());
            }
        }
    }
    if !fonts.families.contains_key(&FontFamily::Name("bold".into())) {
        let prop = fonts.families[&FontFamily::Proportional].clone();
        fonts.families.insert(FontFamily::Name("bold".into()), prop);
    }
    ctx.set_fonts(fonts);
}

pub fn bold(size: f32) -> egui::FontId {
    egui::FontId::new(size, FontFamily::Name("bold".into()))
}

/// Category colours (the Mac's defaults).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Category {
    Cpu,
    Memory,
    Disk,
    Network,
    Gpu,
    Thermal,
    Battery,
    Bench,
    Awake,
}

pub fn category_color(c: Category) -> Color32 {
    match c {
        Category::Cpu => Color32::from_rgb(0x3B, 0x8B, 0xF6),
        Category::Memory => Color32::from_rgb(0x34, 0xC7, 0x59),
        Category::Disk => Color32::from_rgb(0xFF, 0x95, 0x00),
        Category::Network => Color32::from_rgb(0x32, 0xAD, 0xE6),
        Category::Gpu => Color32::from_rgb(0xAF, 0x52, 0xDE),
        Category::Thermal => Color32::from_rgb(0xFF, 0x6B, 0x5A),
        Category::Battery => Color32::from_rgb(0x30, 0xD1, 0x58),
        Category::Bench => Color32::from_rgb(0xFF, 0x2D, 0x55),
        Category::Awake => Color32::from_rgb(0xA2, 0x84, 0x5E),
    }
}

/// Colour for a metric honouring Settings › Tray colours (category / monochrome / custom).
pub fn accent(c: Category, override_: &str, dark: bool) -> Color32 {
    match override_ {
        "" => category_color(c),
        "monochrome" => {
            if dark {
                Color32::from_gray(230)
            } else {
                Color32::from_gray(40)
            }
        }
        hex => parse_hex(hex).unwrap_or_else(|| category_color(c)),
    }
}

pub fn parse_hex(s: &str) -> Option<Color32> {
    let h = s.trim().trim_start_matches('#');
    if h.len() != 6 {
        return None;
    }
    let v = u32::from_str_radix(h, 16).ok()?;
    Some(Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8))
}

/// Green → yellow → orange → red by load (Settings › Colorize by utilization).
pub fn load_color(pct: f64) -> Color32 {
    if pct < 50.0 {
        Color32::from_rgb(0x34, 0xC7, 0x59)
    } else if pct < 75.0 {
        Color32::from_rgb(0xFF, 0xCC, 0x00)
    } else if pct < 90.0 {
        Color32::from_rgb(0xFF, 0x95, 0x00)
    } else {
        Color32::from_rgb(0xFF, 0x3B, 0x30)
    }
}

pub const GREEN: Color32 = Color32::from_rgb(0x34, 0xC7, 0x59);
pub const ORANGE: Color32 = Color32::from_rgb(0xFF, 0x95, 0x00);
pub const RED: Color32 = Color32::from_rgb(0xFF, 0x3B, 0x30);
pub const BLUE: Color32 = Color32::from_rgb(0x0A, 0x84, 0xFF);
pub const YELLOW: Color32 = Color32::from_rgb(0xFF, 0xCC, 0x00);
pub const MINT: Color32 = Color32::from_rgb(0x00, 0xC7, 0xBE);

pub fn ping_color(ms: f64) -> Color32 {
    if ms < 30.0 {
        GREEN
    } else if ms < 80.0 {
        YELLOW
    } else if ms < 150.0 {
        ORANGE
    } else {
        RED
    }
}

/// Blip's look for both light and dark; `ctx.set_theme` then follows Settings › Appearance.
pub fn install_styles(ctx: &egui::Context) {
    for theme in [egui::Theme::Dark, egui::Theme::Light] {
        let dark = theme == egui::Theme::Dark;
        let mut v = if dark {
            egui::Visuals::dark()
        } else {
            egui::Visuals::light()
        };
        v.window_corner_radius = egui::CornerRadius::same(10);
        v.panel_fill = if dark {
            Color32::from_rgb(0x20, 0x20, 0x22)
        } else {
            Color32::from_rgb(0xF7, 0xF7, 0xF8)
        };
        v.window_fill = v.panel_fill;
        v.extreme_bg_color = if dark {
            Color32::from_rgb(0x16, 0x16, 0x18)
        } else {
            Color32::WHITE
        };
        v.selection.bg_fill = BLUE;
        v.hyperlink_color = BLUE;
        ctx.set_visuals_of(theme, v);
        ctx.style_mut_of(theme, |s| {
            s.spacing.item_spacing = Vec2::new(6.0, 4.0);
            s.spacing.button_padding = Vec2::new(8.0, 3.0);
            s.spacing.interact_size.y = 20.0;
            s.interaction.tooltip_delay = 0.4;
            use egui::TextStyle::*;
            s.text_styles.insert(Body, egui::FontId::proportional(12.5));
            s.text_styles.insert(Button, egui::FontId::proportional(12.5));
            s.text_styles.insert(Small, egui::FontId::proportional(10.5));
            s.text_styles.insert(Monospace, egui::FontId::monospace(11.5));
            s.text_styles.insert(Heading, bold(15.0));
        });
    }
}

pub fn secondary(ui: &egui::Ui) -> Color32 {
    ui.visuals().weak_text_color()
}

pub fn tertiary(ui: &egui::Ui) -> Color32 {
    let c = ui.visuals().weak_text_color();
    Color32::from_rgba_unmultiplied(c.r(), c.g(), c.b(), 150)
}

/// Draws a vector icon into `rect`.
pub fn paint_icon(p: &egui::Painter, rect: Rect, icon: Icon, color: Color32) {
    let c = rect.center();
    let s = rect.width().min(rect.height());
    let u = s / 16.0; // design grid: 16×16
    let at = |x: f32, y: f32| Pos2::new(c.x + (x - 8.0) * u, c.y + (y - 8.0) * u);
    let w = (1.3 * u).max(1.0);
    let st = Stroke::new(w, color);
    let rr = |x0: f32, y0: f32, x1: f32, y1: f32| Rect::from_two_pos(at(x0, y0), at(x1, y1));
    let line = |a: (f32, f32), b: (f32, f32)| p.line_segment([at(a.0, a.1), at(b.0, b.1)], st);
    let poly = |pts: &[(f32, f32)], closed: bool| {
        let pts: Vec<Pos2> = pts.iter().map(|(x, y)| at(*x, *y)).collect();
        if closed {
            p.add(PathShape::closed_line(pts, PathStroke::new(w, color)));
        } else {
            p.add(PathShape::line(pts, PathStroke::new(w, color)));
        }
    };
    let arc = |cx: f32, cy: f32, r: f32, a0: f32, a1: f32| {
        let n = 16;
        let pts: Vec<(f32, f32)> = (0..=n)
            .map(|i| {
                let a = a0 + (a1 - a0) * i as f32 / n as f32;
                (cx + r * a.cos(), cy + r * a.sin())
            })
            .collect();
        poly(&pts, false);
    };
    let k = egui::StrokeKind::Middle;
    use std::f32::consts::PI;
    match icon {
        Icon::Cpu => {
            p.rect_stroke(rr(4.0, 4.0, 12.0, 12.0), 1.5 * u, st, k);
            p.rect_filled(rr(6.5, 6.5, 9.5, 9.5), 0.5 * u, color);
            for i in [6.0, 8.0, 10.0] {
                line((i, 1.5), (i, 4.0));
                line((i, 12.0), (i, 14.5));
                line((1.5, i), (4.0, i));
                line((12.0, i), (14.5, i));
            }
        }
        Icon::Memory => {
            p.rect_stroke(rr(1.5, 4.5, 14.5, 11.0), 1.0 * u, st, k);
            for i in [4.5, 7.0, 9.5, 12.0] {
                p.rect_filled(rr(i - 0.8, 6.5, i + 0.8, 9.0), 0.0, color);
            }
            for i in [3.5, 6.0, 8.5, 11.0, 13.0] {
                line((i, 11.0), (i, 13.0));
            }
        }
        Icon::Disk => {
            p.rect_stroke(rr(1.5, 5.0, 14.5, 12.0), 2.0 * u, st, k);
            line((1.8, 9.0), (14.2, 9.0));
            p.circle_filled(at(11.8, 10.6), 0.9 * u, color);
        }
        Icon::Network | Icon::Wifi => {
            p.circle_filled(at(8.0, 12.5), 1.2 * u, color);
            arc(8.0, 12.5, 3.6, -PI * 0.78, -PI * 0.22);
            arc(8.0, 12.5, 6.6, -PI * 0.78, -PI * 0.22);
            arc(8.0, 12.5, 9.6, -PI * 0.76, -PI * 0.24);
        }
        Icon::Ethernet => {
            p.rect_stroke(rr(3.0, 3.0, 13.0, 11.0), 1.0 * u, st, k);
            poly(&[(6.0, 11.0), (6.0, 13.5), (10.0, 13.5), (10.0, 11.0)], false);
            for i in [5.5, 7.2, 8.8, 10.5] {
                line((i, 4.5), (i, 6.5));
            }
        }
        Icon::Gpu => {
            p.rect_stroke(rr(1.5, 4.0, 14.5, 12.0), 1.0 * u, st, k);
            p.circle_stroke(at(6.0, 8.0), 2.2 * u, st);
            p.rect_filled(rr(10.0, 6.0, 12.5, 10.0), 0.5 * u, color);
            line((3.0, 12.0), (3.0, 14.0));
        }
        Icon::Thermometer => {
            p.rect_stroke(rr(6.5, 1.5, 9.5, 10.0), 1.5 * u, st, k);
            p.circle_filled(at(8.0, 12.0), 2.6 * u, color);
            p.rect_filled(rr(7.3, 5.0, 8.7, 11.0), 0.0, color);
        }
        Icon::Battery | Icon::BatteryCharging => {
            p.rect_stroke(rr(1.5, 4.5, 13.0, 11.5), 1.5 * u, st, k);
            p.rect_filled(rr(13.5, 6.5, 14.8, 9.5), 0.5 * u, color);
            if icon == Icon::BatteryCharging {
                let pts = [
                    (8.5, 5.5),
                    (5.5, 8.5),
                    (7.7, 8.5),
                    (6.8, 10.8),
                    (10.0, 7.5),
                    (7.8, 7.5),
                ];
                p.add(egui::Shape::convex_polygon(
                    pts[..3].iter().map(|(x, y)| at(*x, *y)).collect(),
                    color,
                    Stroke::NONE,
                ));
                p.add(egui::Shape::convex_polygon(
                    pts[3..].iter().map(|(x, y)| at(*x, *y)).collect(),
                    color,
                    Stroke::NONE,
                ));
                line((8.5, 5.5), (6.8, 10.8));
            } else {
                p.rect_filled(rr(3.2, 6.2, 9.5, 9.8), 0.5 * u, color);
            }
        }
        Icon::Bench | Icon::Speed => {
            arc(8.0, 10.0, 6.0, PI, 2.0 * PI);
            line((8.0, 10.0), (11.5, 5.8));
            p.circle_filled(at(8.0, 10.0), 1.2 * u, color);
            line((2.0, 10.0), (2.0, 11.5));
            line((14.0, 10.0), (14.0, 11.5));
        }
        Icon::Awake => {
            p.rect_stroke(rr(2.5, 5.5, 11.0, 13.5), 2.0 * u, st, k);
            arc(11.0, 8.5, 2.2, -PI / 2.0, PI / 2.0);
            arc(5.0, 3.5, 1.2, PI, 2.0 * PI);
            arc(8.0, 3.5, 1.2, 0.0, PI);
        }
        Icon::Warning => {
            poly(&[(8.0, 1.5), (15.0, 14.0), (1.0, 14.0)], true);
            line((8.0, 6.0), (8.0, 10.0));
            p.circle_filled(at(8.0, 12.0), 0.8 * u, color);
        }
        Icon::Info => {
            p.circle_stroke(at(8.0, 8.0), 6.5 * u, st);
            line((8.0, 7.0), (8.0, 11.5));
            p.circle_filled(at(8.0, 4.8), 0.8 * u, color);
        }
        Icon::Settings => {
            p.circle_stroke(at(8.0, 8.0), 2.3 * u, st);
            for i in 0..8 {
                let a = i as f32 * PI / 4.0;
                let (sx, sy) = (a.cos(), a.sin());
                line((8.0 + sx * 4.6, 8.0 + sy * 4.6), (8.0 + sx * 6.6, 8.0 + sy * 6.6));
            }
            p.circle_stroke(at(8.0, 8.0), 4.6 * u, st);
        }
        Icon::Power => {
            arc(8.0, 8.8, 5.5, -PI * 0.3, PI * 1.3);
            line((8.0, 1.5), (8.0, 8.0));
        }
        Icon::Pin | Icon::Pinned => {
            let pts = [
                (5.0, 2.0),
                (11.0, 2.0),
                (10.0, 7.0),
                (12.0, 9.5),
                (4.0, 9.5),
                (6.0, 7.0),
            ];
            if icon == Icon::Pinned {
                p.add(egui::Shape::convex_polygon(
                    pts.iter().map(|(x, y)| at(*x, *y)).collect(),
                    color,
                    Stroke::NONE,
                ));
            } else {
                poly(&pts, true);
            }
            line((8.0, 9.5), (8.0, 14.5));
        }
        Icon::Share => {
            poly(
                &[
                    (5.5, 6.5),
                    (3.0, 6.5),
                    (3.0, 14.0),
                    (13.0, 14.0),
                    (13.0, 6.5),
                    (10.5, 6.5),
                ],
                false,
            );
            line((8.0, 1.5), (8.0, 10.0));
            poly(&[(5.2, 4.3), (8.0, 1.5), (10.8, 4.3)], false);
        }
        Icon::Clock => {
            p.circle_stroke(at(8.0, 8.0), 6.3 * u, st);
            poly(&[(8.0, 4.0), (8.0, 8.0), (10.8, 9.6)], false);
        }
        Icon::Computer => {
            p.rect_stroke(rr(3.0, 3.0, 13.0, 10.0), 1.0 * u, st, k);
            poly(&[(1.0, 12.5), (15.0, 12.5)], false);
            line((2.0, 12.5), (3.0, 10.0));
            line((14.0, 12.5), (13.0, 10.0));
        }
        Icon::Windows => {
            for (x, y) in [(2.5, 2.5), (8.5, 2.5), (2.5, 8.5), (8.5, 8.5)] {
                p.rect_filled(rr(x, y, x + 5.0, y + 5.0), 0.0, color);
            }
        }
        Icon::Route => {
            p.circle_stroke(at(3.5, 12.5), 1.6 * u, st);
            p.circle_stroke(at(12.5, 3.5), 1.6 * u, st);
            poly(
                &[
                    (5.0, 12.5),
                    (10.0, 12.5),
                    (10.0, 8.0),
                    (6.0, 8.0),
                    (6.0, 3.5),
                    (11.0, 3.5),
                ],
                false,
            );
        }
        Icon::Map | Icon::Globe => {
            p.circle_stroke(at(8.0, 8.0), 6.5 * u, st);
            line((1.5, 8.0), (14.5, 8.0));
            arc(8.0, 8.0, 6.5, -PI / 2.0, PI / 2.0);
            let pts: Vec<(f32, f32)> = (0..=16)
                .map(|i| {
                    let a = -PI / 2.0 + PI * i as f32 / 16.0;
                    (8.0 - 2.8 * a.cos(), 8.0 + 6.5 * a.sin())
                })
                .collect();
            poly(&pts, false);
            let pts: Vec<(f32, f32)> = (0..=16)
                .map(|i| {
                    let a = -PI / 2.0 + PI * i as f32 / 16.0;
                    (8.0 + 2.8 * a.cos(), 8.0 + 6.5 * a.sin())
                })
                .collect();
            poly(&pts, false);
        }
        Icon::Copy => {
            p.rect_stroke(rr(5.0, 5.0, 13.5, 14.0), 1.5 * u, st, k);
            poly(
                &[(3.0, 11.0), (2.5, 11.0), (2.5, 2.0), (11.0, 2.0), (11.0, 3.0)],
                false,
            );
        }
        Icon::Close | Icon::Kill => {
            if icon == Icon::Kill {
                p.circle_stroke(at(8.0, 8.0), 6.3 * u, st);
                line((5.5, 5.5), (10.5, 10.5));
                line((10.5, 5.5), (5.5, 10.5));
            } else {
                line((3.5, 3.5), (12.5, 12.5));
                line((12.5, 3.5), (3.5, 12.5));
            }
        }
        Icon::Play => {
            p.add(egui::Shape::convex_polygon(
                vec![at(4.5, 2.5), at(13.0, 8.0), at(4.5, 13.5)],
                color,
                Stroke::NONE,
            ));
        }
        Icon::Stop => {
            p.rect_filled(rr(3.5, 3.5, 12.5, 12.5), 1.5 * u, color);
        }
        Icon::Refresh => {
            arc(8.0, 8.0, 5.5, -PI * 0.1, PI * 1.6);
            poly(&[(10.8, 1.8), (13.6, 3.6), (11.2, 6.0)], false);
        }
        Icon::ChevronRight => poly(&[(6.0, 3.5), (10.5, 8.0), (6.0, 12.5)], false),
        Icon::ChevronDown => poly(&[(3.5, 6.0), (8.0, 10.5), (12.5, 6.0)], false),
        Icon::Up => {
            line((8.0, 2.5), (8.0, 13.5));
            poly(&[(4.0, 6.5), (8.0, 2.5), (12.0, 6.5)], false);
        }
        Icon::Down => {
            line((8.0, 2.5), (8.0, 13.5));
            poly(&[(4.0, 9.5), (8.0, 13.5), (12.0, 9.5)], false);
        }
        Icon::Check => poly(&[(3.0, 8.5), (6.5, 12.0), (13.0, 4.5)], false),
        Icon::Fan => {
            p.circle_filled(at(8.0, 8.0), 1.4 * u, color);
            for i in 0..3 {
                let a = i as f32 * 2.0 * PI / 3.0;
                let tip = (8.0 + 6.0 * a.cos(), 8.0 + 6.0 * a.sin());
                let side = (8.0 + 4.5 * (a + 0.9).cos(), 8.0 + 4.5 * (a + 0.9).sin());
                p.add(egui::Shape::convex_polygon(
                    vec![at(8.0, 8.0), at(tip.0, tip.1), at(side.0, side.1)],
                    color,
                    Stroke::NONE,
                ));
            }
        }
        Icon::Lifebuoy => {
            p.circle_stroke(at(8.0, 8.0), 6.3 * u, st);
            p.circle_stroke(at(8.0, 8.0), 2.8 * u, st);
            for a in [PI / 4.0, 3.0 * PI / 4.0, 5.0 * PI / 4.0, 7.0 * PI / 4.0] {
                line(
                    (8.0 + 2.8 * a.cos(), 8.0 + 2.8 * a.sin()),
                    (8.0 + 6.3 * a.cos(), 8.0 + 6.3 * a.sin()),
                );
            }
        }
        Icon::Folder => {
            poly(
                &[
                    (1.5, 4.0),
                    (6.0, 4.0),
                    (7.5, 5.5),
                    (14.5, 5.5),
                    (14.5, 13.0),
                    (1.5, 13.0),
                ],
                true,
            );
        }
        Icon::Shield => {
            poly(
                &[
                    (8.0, 1.5),
                    (14.0, 3.5),
                    (13.5, 9.0),
                    (8.0, 14.5),
                    (2.5, 9.0),
                    (2.0, 3.5),
                ],
                true,
            );
        }
    }
}

/// An icon as a widget.
pub fn icon(ui: &mut egui::Ui, icon: Icon, size: f32, color: Color32) -> egui::Response {
    let (rect, resp) = ui.allocate_exact_size(Vec2::splat(size), egui::Sense::hover());
    paint_icon(ui.painter(), rect, icon, color);
    resp
}

/// A borderless icon button with a hover wash.
pub fn icon_button(ui: &mut egui::Ui, ic: Icon, size: f32, color: Color32, tip: &str) -> egui::Response {
    let (rect, resp) = ui.allocate_exact_size(Vec2::splat(size + 6.0), egui::Sense::click());
    if resp.hovered() {
        ui.painter()
            .rect_filled(rect, 4.0, ui.visuals().widgets.hovered.weak_bg_fill);
    }
    paint_icon(ui.painter(), rect.shrink(3.0), ic, color);
    if tip.is_empty() {
        resp
    } else {
        resp.on_hover_text(tip)
    }
}
