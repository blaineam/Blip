//! The popover: one row per section (hover or click for details), the system footer, and the
//! suggestion banner at the bottom so its changing height never shifts the rows.

use eframe::egui::{self, Color32, FontId, Rect, RichText, Sense, Vec2};

use blip_core::model::Snapshot;
use blip_core::settings::{DetailStyle, Settings};
use blip_core::{fmt, t, tf, Icon};

use crate::panels::system::thermal_color;
use crate::sections::{Section, ALL};
use crate::state::App;
use crate::theme::{self, secondary, tertiary};
use crate::widgets;

pub const WIDTH: f32 = 260.0;

#[derive(Default)]
pub struct Outcome {
    /// Row under the pointer and its rect (window coordinates).
    pub hovered: Option<(Section, Rect)>,
    pub clicked: Option<Section>,
    pub open_settings: bool,
    pub toggle_pin: bool,
    pub quit: bool,
    pub share: bool,
    pub support: bool,
    pub dismiss: Option<String>,
    pub drag: bool,
}

pub fn visible_sections(s: &Snapshot) -> Vec<Section> {
    ALL.iter()
        .copied()
        .filter(|sec| match sec {
            Section::Gpu => s.gpu.available,
            Section::Battery => s.battery.present,
            _ => true,
        })
        .collect()
}

fn value_cell(ui: &mut egui::Ui, sec: Section, s: &Snapshot, app: &App, set: &Settings, color: Color32) {
    let bar = |ui: &mut egui::Ui, pct: f64| {
        let col = if set.colorize_utilization {
            theme::load_color(pct)
        } else {
            color
        };
        widgets::usage_bar(ui, 64.0, 5.0, pct, col);
        ui.add_space(4.0);
        ui.allocate_ui(Vec2::new(34.0, 14.0), |ui| {
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label(
                    RichText::new(fmt::percent(pct))
                        .font(FontId::monospace(10.5))
                        .color(secondary(ui)),
                );
            });
        });
    };
    match sec {
        Section::Cpu => bar(ui, s.cpu.total),
        Section::Memory => bar(ui, s.memory.usage_pct()),
        Section::Disk => bar(ui, s.disk.system_volume().map_or(0.0, |v| v.usage_pct())),
        Section::Gpu => bar(ui, s.gpu.utilization),
        Section::Battery => bar(ui, s.battery.level),
        Section::Network => {
            ui.label(
                RichText::new(format!(
                    "↓{} ↑{}",
                    fmt::short_speed(s.network.down_bps),
                    fmt::short_speed(s.network.up_bps)
                ))
                .font(FontId::monospace(10.5)),
            );
        }
        Section::Thermal => {
            ui.label(
                RichText::new(t(s.thermal.level.english()))
                    .font(FontId::monospace(10.5))
                    .color(thermal_color(s.thermal.level)),
            );
        }
        Section::Bench => {
            let st = app.bench.state();
            let txt = if st.running {
                t("running…")
            } else if let Some(r) = &st.last_result {
                format!("{:.0}", r.composite)
            } else {
                t("run")
            };
            ui.label(
                RichText::new(txt)
                    .font(FontId::monospace(10.5))
                    .color(if st.running {
                        color
                    } else {
                        ui.visuals().text_color()
                    }),
            );
        }
        Section::Awake => {
            let (txt, col) = match app.awake() {
                Some(a) => (
                    a.until
                        .map(|u| tf("Until %@", &[&crate::timefmt::time(u)]))
                        .unwrap_or_else(|| t("On")),
                    theme::GREEN,
                ),
                None => (t("Off"), secondary(ui)),
            };
            ui.label(RichText::new(txt).font(FontId::monospace(10.5)).color(col));
        }
    }
}

pub fn show(
    ui: &mut egui::Ui,
    app: &App,
    snap: &Snapshot,
    set: &Settings,
    active: Option<Section>,
    inline: &mut dyn FnMut(&mut egui::Ui, Section),
) -> Outcome {
    let mut out = Outcome::default();
    let dark = ui.visuals().dark_mode;
    ui.spacing_mut().item_spacing.y = 0.0;
    for sec in visible_sections(snap) {
        let color = theme::accent(sec.category(), &set.accent_color_override, dark);
        let (rect, resp) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 24.0), Sense::click());
        let highlighted = resp.hovered() || active == Some(sec);
        if highlighted {
            ui.painter().rect_filled(
                rect.shrink2(Vec2::new(4.0, 1.0)),
                5.0,
                ui.visuals().widgets.hovered.weak_bg_fill,
            );
        }
        let mut row = ui.new_child(
            egui::UiBuilder::new()
                .max_rect(rect.shrink2(Vec2::new(10.0, 0.0)))
                .layout(egui::Layout::left_to_right(egui::Align::Center)),
        );
        theme::icon(&mut row, sec.icon(), 13.0, color);
        row.add_space(4.0);
        row.label(RichText::new(sec.title()).font(theme::bold(12.0)));
        row.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            theme::icon(
                ui,
                if set.detail_panel_style == DetailStyle::Inline && active == Some(sec) {
                    Icon::ChevronDown
                } else {
                    Icon::ChevronRight
                },
                9.0,
                tertiary(ui),
            );
            ui.add_space(2.0);
            ui.with_layout(egui::Layout::left_to_right(egui::Align::Center), |ui| {
                ui.add_space((ui.available_width() - 104.0).max(0.0));
                value_cell(ui, sec, snap, app, set, color);
            });
        });
        if resp.hovered() {
            out.hovered = Some((sec, rect));
        }
        if resp.clicked() {
            out.clicked = Some(sec);
        }
        if set.detail_panel_style == DetailStyle::Inline && active == Some(sec) {
            ui.add_space(4.0);
            egui::Frame::new()
                .inner_margin(egui::Margin::symmetric(10, 4))
                .show(ui, |ui| inline(ui, sec));
            ui.add_space(4.0);
        }
    }
    ui.spacing_mut().item_spacing.y = 3.0;
    ui.add_space(4.0);
    ui.separator();

    // Footer.
    egui::Frame::new()
        .inner_margin(egui::Margin::symmetric(10, 2))
        .show(ui, |ui| {
            let foot = |ui: &mut egui::Ui, ic: Icon, text: &str, weak: bool| {
                ui.horizontal(|ui| {
                    theme::icon(ui, ic, 9.0, secondary(ui));
                    ui.label(RichText::new(text).size(10.0).color(if weak {
                        tertiary(ui)
                    } else {
                        secondary(ui)
                    }));
                });
            };
            let model = if snap.system.model.is_empty() {
                snap.system.host_name.clone()
            } else {
                snap.system.model.clone()
            };
            if !model.is_empty() {
                foot(ui, Icon::Computer, &model, false);
            }
            foot(
                ui,
                if cfg!(windows) { Icon::Windows } else { Icon::Linux },
                format!("{} {}", snap.system.os_name, snap.system.os_version).trim(),
                true,
            );
            foot(ui, Icon::Clock, &fmt::uptime(snap.system.uptime_secs), false);
            let r = ui
                .horizontal(|ui| {
                    theme::icon(ui, Icon::Lifebuoy, 9.0, secondary(ui));
                    ui.label(
                        RichText::new(t("Support & Feedback"))
                            .size(10.0)
                            .color(secondary(ui)),
                    );
                })
                .response
                .interact(Sense::click());
            if r.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                out.support = true;
            }
            ui.horizontal(|ui| {
                let mb = format!("{:.1}", snap.system.blip_memory as f64 / 1_048_576.0);
                let version = tf("Blip v%@ · %@ MB", &[&crate::VERSION, &mb]);
                let r = ui.add(
                    egui::Label::new(RichText::new(version).size(9.0).color(tertiary(ui)))
                        .sense(Sense::drag()),
                );
                if r.drag_started() {
                    out.drag = true;
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if theme::icon_button(ui, Icon::Power, 11.0, secondary(ui), &t("Quit Blip")).clicked() {
                        out.quit = true;
                    }
                    if theme::icon_button(ui, Icon::Settings, 11.0, secondary(ui), &t("Settings")).clicked() {
                        out.open_settings = true;
                    }
                    let pinned = set.popover_pinned;
                    let (pi, pc, tip) = if pinned {
                        (
                            Icon::Pinned,
                            theme::ORANGE,
                            t("Unpin — close when clicking elsewhere"),
                        )
                    } else {
                        (
                            Icon::Pin,
                            secondary(ui),
                            t("Pin open — stays up, and can be dragged off into its own window"),
                        )
                    };
                    if theme::icon_button(ui, pi, 11.0, pc, &tip).clicked() {
                        out.toggle_pin = true;
                    }
                    if theme::icon_button(
                        ui,
                        Icon::Share,
                        11.0,
                        secondary(ui),
                        &t("Share a snapshot of all stats as one file"),
                    )
                    .clicked()
                    {
                        out.share = true;
                    }
                });
            });
        });

    if set.show_recommendations {
        let rec = app.live.read().unwrap().recommendations.first().cloned();
        if let Some(rec) = rec {
            ui.separator();
            let col = match rec.severity {
                blip_core::recommend::Severity::Critical => theme::RED,
                blip_core::recommend::Severity::Warning => theme::ORANGE,
                blip_core::recommend::Severity::Info => theme::BLUE,
            };
            egui::Frame::new()
                .inner_margin(egui::Margin::symmetric(10, 4))
                .show(ui, |ui| {
                    ui.horizontal_top(|ui| {
                        theme::icon(ui, rec.icon, 13.0, col);
                        ui.vertical(|ui| {
                            ui.set_width(WIDTH - 60.0);
                            ui.label(RichText::new(&rec.title).font(theme::bold(11.0)));
                            ui.label(RichText::new(&rec.detail).size(10.0).color(secondary(ui)));
                        });
                        if theme::icon_button(ui, Icon::Close, 8.0, tertiary(ui), &t("Dismiss")).clicked() {
                            out.dismiss = Some(rec.id.clone());
                        }
                    });
                });
        }
    }
    out
}
