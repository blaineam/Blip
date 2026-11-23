//! Blip Bench: run, watch legs land live, read the score (same frozen units as the Mac and
//! iPhone), sustained-load throttling, and on-device history.

use eframe::egui::{self, FontId, RichText, Vec2};

use blip_core::bench::{BenchResult, Phase, Profile};
use blip_core::{t, tf, Icon};

use super::{divider, header, section_label, Ctx};
use crate::sections::Section;
use crate::theme::{self, secondary};
use crate::widgets;

fn leg_row(ui: &mut egui::Ui, width: f32, name: &str, score: f64, max: f64, color: egui::Color32) {
    ui.horizontal(|ui| {
        ui.allocate_ui(Vec2::new(90.0, 14.0), |ui| {
            ui.set_width(90.0);
            ui.label(RichText::new(name).size(11.0));
        });
        widgets::usage_bar(ui, width - 150.0, 6.0, (score / max * 100.0).min(100.0), color);
        ui.label(RichText::new(format!("{:.0}", score)).font(FontId::monospace(11.5)));
    });
}

pub fn show(ui: &mut egui::Ui, c: &mut Ctx) {
    let st = c.app.bench.state();
    let color = c.color(Section::Bench);
    header(ui, c, Section::Bench, |ui| {
        if let Some(r) = &st.last_result {
            if !st.running {
                ui.label(
                    RichText::new(format!("{:.0}", r.composite))
                        .font(FontId::monospace(14.0))
                        .color(color),
                );
            }
        }
    });
    if st.running {
        ui.horizontal(|ui| {
            ui.spinner();
            ui.label(RichText::new(st.phase.label()).size(11.5));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button(t("Cancel")).clicked() {
                    c.app.bench.cancel();
                }
            });
        });
        widgets::progress(ui, c.width, st.progress, color);
        let max = st
            .live_legs
            .iter()
            .filter(|l| l.id != "sustained")
            .map(|l| l.score)
            .fold(1.0, f64::max);
        for l in &st.live_legs {
            if l.id == "sustained" {
                widgets::kv(
                    ui,
                    &t("Sustained + thermals"),
                    &tf("%lld%% held", &[&(l.score.round() as i64)]),
                );
            } else {
                leg_row(ui, c.width, &l.name, l.score, max, color);
            }
        }
        if let Some(th) = &st.live_thermal {
            if let Some(tc) = th.temperature_c {
                widgets::kv(ui, &t("Temperature"), &blip_core::fmt::temperature(tc));
            }
        }
        ui.label(
            RichText::new(t(
                "Keep the PC plugged in and other apps quiet for the most honest score.",
            ))
            .size(10.0)
            .color(theme::tertiary(ui)),
        );
    } else {
        ui.label(
            RichText::new(t("Measure what this PC can actually do — CPU, memory, and GPU throughput scored in Blip's fixed reference units, plus how much it loses under sustained load."))
                .size(10.5)
                .color(secondary(ui)),
        );
        ui.horizontal(|ui| {
            if ui
                .add(
                    egui::Button::new(RichText::new(format!("▶  {}", t("Run Benchmark"))).color(theme::BLUE))
                        .frame(false),
                )
                .clicked()
            {
                c.app.bench.start(Profile::Full, c.app.repaint_fn());
            }
            if ui
                .add(
                    egui::Button::new(RichText::new(t("Quick run")).size(11.0).color(secondary(ui)))
                        .frame(false),
                )
                .on_hover_text(t("About 6 seconds, no sustained phase"))
                .clicked()
            {
                c.app.bench.start(Profile::Quick, c.app.repaint_fn());
            }
        });
        ui.label(
            RichText::new(t("Takes about 90 seconds and runs every core flat out."))
                .size(10.0)
                .color(theme::tertiary(ui)),
        );
    }

    if let Some(r) = st.last_result.as_ref().filter(|_| !st.running) {
        divider(ui);
        result(ui, c, r, &st.history);
    }
}

fn result(ui: &mut egui::Ui, c: &mut Ctx, r: &BenchResult, history: &[BenchResult]) {
    let color = c.color(Section::Bench);
    ui.horizontal(|ui| {
        ui.label(
            RichText::new(format!("{:.0}", r.composite))
                .font(theme::bold(28.0))
                .color(color),
        );
        ui.vertical(|ui| {
            ui.label(RichText::new(t("composite")).size(10.5).color(secondary(ui)));
            if let Some(best) = c.app.bench.personal_best() {
                let d = (r.composite / best - 1.0) * 100.0;
                let txt = if d >= -0.5 {
                    t("Personal best")
                } else {
                    tf("%lld%% vs best", &[&(d.round() as i64)])
                };
                ui.label(RichText::new(txt).size(10.5).color(if d >= -0.5 {
                    theme::GREEN
                } else {
                    secondary(ui)
                }));
            }
        });
    });
    let cats: Vec<(String, f64)> = [
        Some(&r.single_core),
        Some(&r.multi_core),
        Some(&r.memory),
        r.gpu.as_ref(),
        r.neural.as_ref(),
    ]
    .into_iter()
    .flatten()
    .map(|c| (t(&c.name), c.score))
    .collect();
    let max = cats.iter().map(|c| c.1).fold(1.0, f64::max);
    for (name, score) in &cats {
        leg_row(ui, c.width, name, *score, max, color);
    }
    if let Some(lost) = r.throttle_percent_lost() {
        let col = if lost > 15 { theme::ORANGE } else { theme::GREEN };
        widgets::kv_colored(
            ui,
            &t("Sustained + thermals"),
            &tf("Sustained −%lld%%", &[&lost]),
            col,
        );
    }
    if r.gpu.is_none() {
        ui.label(
            RichText::new(t(
                "GPU leg unavailable on this PC — the score uses the other categories.",
            ))
            .size(10.0)
            .color(theme::tertiary(ui)),
        );
    }
    ui.label(
        RichText::new(format!(
            "{} · {}",
            r.device_model,
            crate::timefmt::date_time(r.date)
        ))
        .size(10.0)
        .color(theme::tertiary(ui)),
    );
    let full: Vec<f64> = history
        .iter()
        .filter(|h| h.profile == Profile::Full)
        .map(|h| h.composite)
        .collect();
    if full.len() > 1 {
        section_label(ui, &t("History"));
        let max = full.iter().copied().fold(1.0, f64::max) * 1.1;
        widgets::sparkline(ui, Vec2::new(c.width, 36.0), &full, Some(max), color);
    }
    ui.horizontal(|ui| {
        if theme::icon_button(ui, Icon::Copy, 11.0, secondary(ui), &t("Copy")).clicked() {
            let txt = format!(
                "Blip Bench {:.0} — single-core {:.0}, all cores {:.0}, memory {:.0}{} · {}",
                r.composite,
                r.single_core.score,
                r.multi_core.score,
                r.memory.score,
                r.gpu
                    .as_ref()
                    .map(|g| format!(", GPU {:.0}", g.score))
                    .unwrap_or_default(),
                r.device_model
            );
            ui.ctx().copy_text(txt);
            c.actions.push(super::Action::Toast(t("Copied")));
        }
    });
    let _ = Phase::Done;
}
