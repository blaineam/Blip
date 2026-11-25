//! Reusable pieces: usage bars, sparklines, the dual-curve I/O chart with Y-axis labels, stat
//! columns, click-to-copy rows, disclosure headers and process rows.

use std::collections::HashMap;

use eframe::egui::{self, Align2, Color32, FontId, Pos2, Rect, RichText, Sense, Stroke, Vec2};
use eframe::epaint::{PathShape, PathStroke};

use blip_core::Icon;

use crate::theme::{self, secondary};

pub fn usage_bar(ui: &mut egui::Ui, width: f32, height: f32, pct: f64, color: Color32) -> egui::Response {
    let (rect, resp) = ui.allocate_exact_size(Vec2::new(width, height), Sense::hover());
    let p = ui.painter();
    let track = if ui.visuals().dark_mode {
        Color32::from_white_alpha(28)
    } else {
        Color32::from_black_alpha(22)
    };
    p.rect_filled(rect, height / 2.0, track);
    let f = (pct / 100.0).clamp(0.0, 1.0) as f32;
    if f > 0.0 {
        let mut r = rect;
        r.set_width((rect.width() * f).max(height));
        p.rect_filled(r, height / 2.0, color);
    }
    resp
}

/// Sparkline with a soft fill, auto-scaled to `max` (or 100 for percentages).
pub fn sparkline(ui: &mut egui::Ui, size: Vec2, values: &[f64], max: Option<f64>, color: Color32) {
    let (rect, _) = ui.allocate_exact_size(size, Sense::hover());
    paint_area(
        ui.painter(),
        rect,
        values,
        max.unwrap_or(100.0).max(1e-9),
        color,
        60,
    );
}

fn paint_area(p: &egui::Painter, rect: Rect, values: &[f64], max: f64, color: Color32, slots: usize) {
    let bg = Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), 18);
    p.rect_filled(rect, 4.0, bg);
    if values.len() < 2 {
        return;
    }
    let n = slots.max(values.len());
    let step = rect.width() / (n - 1) as f32;
    let start = n - values.len();
    let pts: Vec<Pos2> = values
        .iter()
        .enumerate()
        .map(|(i, v)| {
            let x = rect.left() + (start + i) as f32 * step;
            let y = rect.bottom() - (v / max).clamp(0.0, 1.0) as f32 * (rect.height() - 2.0) - 1.0;
            Pos2::new(x, y)
        })
        .collect();
    let fill = Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), 46);
    for w in pts.windows(2) {
        let quad = vec![
            w[0],
            w[1],
            Pos2::new(w[1].x, rect.bottom()),
            Pos2::new(w[0].x, rect.bottom()),
        ];
        p.add(egui::Shape::convex_polygon(quad, fill, Stroke::NONE));
    }
    p.add(PathShape::line(pts, PathStroke::new(1.5, color)));
}

/// Two series (down/up, read/write) on one auto-scaled axis with Y labels on the right.
pub fn dual_chart(
    ui: &mut egui::Ui,
    width: f32,
    height: f32,
    a: (&[f64], Color32, &str),
    b: (&[f64], Color32, &str),
    label: impl Fn(f64) -> String,
) {
    let max =
        blip_core::history::nice_ceiling(a.0.iter().chain(b.0.iter()).copied().fold(0.0, f64::max).max(1.0));
    let axis_w = 52.0;
    let (rect, _) = ui.allocate_exact_size(Vec2::new(width, height), Sense::hover());
    let plot = Rect::from_min_max(rect.min, Pos2::new(rect.right() - axis_w, rect.bottom()));
    let p = ui.painter();
    let grid = if ui.visuals().dark_mode {
        Color32::from_white_alpha(16)
    } else {
        Color32::from_black_alpha(14)
    };
    let weak = secondary(ui);
    for i in 0..=3 {
        let f = i as f32 / 3.0;
        let y = plot.bottom() - f * plot.height();
        p.line_segment(
            [Pos2::new(plot.left(), y), Pos2::new(plot.right(), y)],
            Stroke::new(0.5, grid),
        );
        p.text(
            Pos2::new(rect.right() - 2.0, y),
            Align2::RIGHT_CENTER,
            label(max * f as f64),
            FontId::proportional(9.0),
            weak,
        );
    }
    for (vals, color, _) in [a, b] {
        if vals.len() < 2 {
            continue;
        }
        let n = 60.max(vals.len());
        let step = plot.width() / (n - 1) as f32;
        let start = n - vals.len();
        let pts: Vec<Pos2> = vals
            .iter()
            .enumerate()
            .map(|(i, v)| {
                Pos2::new(
                    plot.left() + (start + i) as f32 * step,
                    plot.bottom() - (v / max).clamp(0.0, 1.0) as f32 * plot.height(),
                )
            })
            .collect();
        let fill = Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), 30);
        for w in pts.windows(2) {
            p.add(egui::Shape::convex_polygon(
                vec![
                    w[0],
                    w[1],
                    Pos2::new(w[1].x, plot.bottom()),
                    Pos2::new(w[0].x, plot.bottom()),
                ],
                fill,
                Stroke::NONE,
            ));
        }
        p.add(PathShape::line(pts, PathStroke::new(1.5, color)));
    }
    ui.horizontal(|ui| {
        for (_, color, name) in [a, b] {
            legend_dot(ui, color, name);
        }
    });
}

pub fn legend_dot(ui: &mut egui::Ui, color: Color32, name: &str) {
    let (r, _) = ui.allocate_exact_size(Vec2::splat(8.0), Sense::hover());
    ui.painter().circle_filled(r.center(), 3.0, color);
    ui.label(RichText::new(name).size(10.0).color(secondary(ui)));
}

/// Small caption over a big number (the panels' stat grid).
pub fn stat(
    ui: &mut egui::Ui,
    icon: Option<(Icon, Color32)>,
    caption: &str,
    value: &str,
    value_color: Option<Color32>,
) {
    ui.vertical(|ui| {
        ui.spacing_mut().item_spacing.y = 1.0;
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 3.0;
            if let Some((ic, c)) = icon {
                theme::icon(ui, ic, 10.0, c);
            }
            ui.label(RichText::new(caption).size(10.5).color(secondary(ui)));
        });
        let mut t = RichText::new(value).font(FontId::monospace(13.0));
        if let Some(c) = value_color {
            t = t.color(c);
        }
        ui.label(t);
    });
}

/// Two stat columns side by side.
pub fn stat_pair(
    ui: &mut egui::Ui,
    width: f32,
    left: impl FnOnce(&mut egui::Ui),
    right: impl FnOnce(&mut egui::Ui),
) {
    ui.horizontal_top(|ui| {
        ui.allocate_ui(Vec2::new(width / 2.0 - 4.0, 0.0), |ui| {
            ui.set_width(width / 2.0 - 4.0);
            left(ui)
        });
        ui.allocate_ui(Vec2::new(width / 2.0 - 4.0, 0.0), |ui| {
            ui.set_width(width / 2.0 - 4.0);
            right(ui)
        });
    });
}

/// "Label ............ value" row.
pub fn kv(ui: &mut egui::Ui, key: &str, value: &str) {
    ui.horizontal(|ui| {
        ui.label(RichText::new(key).size(11.5).color(secondary(ui)));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.label(RichText::new(value).font(FontId::monospace(11.5)));
        });
    });
}

pub fn kv_colored(ui: &mut egui::Ui, key: &str, value: &str, color: Color32) {
    ui.horizontal(|ui| {
        ui.label(RichText::new(key).size(11.5).color(secondary(ui)));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.label(RichText::new(value).font(FontId::monospace(11.5)).color(color));
        });
    });
}

/// Click-to-copy row (addresses, MACs). Returns true when copied this frame.
pub fn kv_copy(ui: &mut egui::Ui, key: &str, value: &str) -> bool {
    let mut copied = false;
    ui.horizontal(|ui| {
        ui.label(RichText::new(key).size(11.5).color(secondary(ui)));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            let id = ui.scope_id().with(("copy", key, value));
            let flash = ui
                .ctx()
                .data(|d| d.get_temp::<f64>(id))
                .is_some_and(|t| ui.input(|i| i.time) - t < 1.2);
            let c = if flash { theme::GREEN } else { secondary(ui) };
            if value != "—"
                && theme::icon_button(
                    ui,
                    if flash { Icon::Check } else { Icon::Copy },
                    10.0,
                    c,
                    &blip_core::t("Copy"),
                )
                .clicked()
            {
                ui.ctx().copy_text(value.to_string());
                let now = ui.input(|i| i.time);
                ui.ctx().data_mut(|d| d.insert_temp(id, now));
                copied = true;
            }
            let r = ui.add(
                egui::Label::new(RichText::new(value).font(FontId::monospace(11.5)))
                    .truncate()
                    .sense(Sense::click()),
            );
            if r.clicked() && value != "—" {
                ui.ctx().copy_text(value.to_string());
                let now = ui.input(|i| i.time);
                ui.ctx().data_mut(|d| d.insert_temp(id, now));
                copied = true;
            }
        });
    });
    copied
}

/// Disclosure header ("▸ Speed Test") persisted in `open`.
pub fn disclosure(ui: &mut egui::Ui, icon: Icon, color: Color32, title: &str, open: &mut bool) -> bool {
    let resp = ui
        .horizontal(|ui| {
            theme::icon(ui, icon, 12.0, color);
            ui.label(RichText::new(title).font(theme::bold(12.5)));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                theme::icon(
                    ui,
                    if *open {
                        Icon::ChevronDown
                    } else {
                        Icon::ChevronRight
                    },
                    10.0,
                    secondary(ui),
                );
            });
        })
        .response
        .interact(Sense::click());
    if resp.clicked() {
        *open = !*open;
        return true;
    }
    false
}

pub fn progress(ui: &mut egui::Ui, width: f32, frac: f64, color: Color32) {
    usage_bar(ui, width, 5.0, frac * 100.0, color);
}

/// Cached 16 px process icons (Windows: the executable's own icon).
#[derive(Default)]
pub struct IconCache {
    map: HashMap<String, Option<egui::TextureHandle>>,
}

impl IconCache {
    pub fn get(&mut self, ctx: &egui::Context, exe: Option<&str>) -> Option<egui::TextureHandle> {
        let exe = exe?;
        if !self.map.contains_key(exe) {
            let tex = blip_platform::exe_icon(exe).map(|(w, h, rgba)| {
                ctx.load_texture(
                    format!("icon:{exe}"),
                    egui::ColorImage::from_rgba_unmultiplied([w as usize, h as usize], &rgba),
                    egui::TextureOptions::LINEAR,
                )
            });
            if self.map.len() > 300 {
                self.map.clear();
            }
            self.map.insert(exe.to_string(), tex);
        }
        self.map.get(exe).cloned().flatten()
    }
}

pub enum RowAction {
    None,
    Kill(u32, String),
}

/// A process row: icon, name, value, and (for the user's own processes) an End button.
pub fn process_row(
    ui: &mut egui::Ui,
    icons: &mut IconCache,
    p: &blip_core::model::ProcessInfo,
    value: &str,
    width: f32,
) -> RowAction {
    let mut action = RowAction::None;
    ui.allocate_ui_with_layout(
        Vec2::new(width, 18.0),
        egui::Layout::left_to_right(egui::Align::Center),
        |ui| {
            ui.set_width(width);
            match icons.get(ui.ctx(), p.exe.as_deref()) {
                Some(t) => {
                    ui.add(egui::Image::new(&t).fit_to_exact_size(Vec2::splat(14.0)));
                }
                None => {
                    let (r, _) = ui.allocate_exact_size(Vec2::splat(14.0), Sense::hover());
                    ui.painter()
                        .rect_filled(r.shrink(1.0), 3.0, Color32::from_gray(120).gamma_multiply(0.4));
                }
            }
            ui.add(
                egui::Label::new(RichText::new(blip_core::recommend::display_name(&p.name)).size(11.5))
                    .truncate(),
            );
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let killable = p.user_owned && !blip_core::recommend::is_system_process(&p.name);
                let row_hovered = ui.rect_contains_pointer(ui.max_rect().expand2(Vec2::new(width, 0.0)));
                if killable && row_hovered {
                    if theme::icon_button(
                        ui,
                        Icon::Kill,
                        10.0,
                        theme::RED,
                        &blip_core::tf("Quit %@", &[&blip_core::recommend::display_name(&p.name)]),
                    )
                    .clicked()
                    {
                        action = RowAction::Kill(p.pid, p.name.clone());
                    }
                } else {
                    ui.add_space(16.0);
                }
                ui.label(
                    RichText::new(value)
                        .font(FontId::monospace(11.0))
                        .color(secondary(ui)),
                );
            });
        },
    );
    action
}

/// A tinted capsule of one line of text. It's a single widget of known size, so in a wrapped row
/// a badge that doesn't fit moves to the next line whole. (A `Frame` around a label can't: the
/// row hands it the leftover width and the text wraps inside, one letter per line.)
pub fn badge(ui: &mut egui::Ui, text: &str, color: egui::Color32) -> egui::Response {
    let galley = ui
        .painter()
        .layout_no_wrap(text.to_string(), egui::FontId::proportional(10.0), color);
    let pad = egui::vec2(5.0, 2.0);
    let (rect, response) = ui.allocate_exact_size(galley.size() + pad * 2.0, egui::Sense::hover());
    if ui.is_rect_visible(rect) {
        ui.painter().rect_filled(rect, 4.0, color.gamma_multiply(0.18));
        ui.painter().galley(rect.min + pad, galley, color);
    }
    response.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Label, true, text));
    response
}

#[cfg(test)]
mod badge_tests {
    use super::*;
    use egui_kittest::Harness;
    use std::sync::{Arc, Mutex};

    /// The speed test's grades in a panel-width row, in the longest languages too.
    #[test]
    fn badges_wrap_whole() {
        let names = [
            "A Browsing",
            "A HD streaming",
            "A 4K streaming",
            "A Video calls",
            "A Cloud gaming",
            "B Videoanrufe in Gruppen",
        ];
        let rects = Arc::new(Mutex::new(Vec::new()));
        let seen = rects.clone();
        let mut h = Harness::builder()
            .with_size(egui::vec2(320.0, 600.0))
            .build_ui(move |ui| {
                let area = egui::Rect::from_min_size(ui.cursor().min, egui::vec2(280.0, 500.0));
                ui.scope_builder(egui::UiBuilder::new().max_rect(area), |ui| {
                    ui.horizontal_wrapped(|ui| {
                        *seen.lock().unwrap() = names
                            .iter()
                            .map(|n| badge(ui, n, egui::Color32::GREEN).rect)
                            .collect();
                    });
                });
            });
        h.run_steps(3);
        let rects = rects.lock().unwrap().clone();
        assert_eq!(rects.len(), names.len());
        let line = rects[0].height();
        let left = rects[0].left();
        for (r, n) in rects.iter().zip(names) {
            assert!(
                line < 20.0 && (r.height() - line).abs() < 1.0,
                "{n} is not one line: {r:?}"
            );
            assert!(r.right() <= left + 281.0, "{n} overflows the panel: {r:?}");
        }
        assert!(
            rects.last().unwrap().top() > rects[0].top(),
            "wraps to a second line"
        );
    }
}
