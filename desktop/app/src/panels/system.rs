//! CPU, Memory, GPU, Thermal, Battery and Keep Awake panels.

use eframe::egui::{self, Color32, FontId, RichText, Vec2};

use blip_core::model::ThermalLevel;
use blip_core::{fmt, t, tf, Icon};
use blip_platform::AwakeOptions;

use super::{divider, header, section_label, Action, Ctx};
use crate::sections::Section;
use crate::theme::{self, secondary};
use crate::widgets::{self, process_row, stat, stat_pair, RowAction};

fn processes(ui: &mut egui::Ui, c: &mut Ctx, by_memory: bool) {
    section_label(ui, &t("Top Processes"));
    let list = if by_memory {
        c.snap.top_memory.clone()
    } else {
        c.snap.top_cpu.clone()
    };
    for p in list.iter().take(6) {
        let value = if by_memory {
            fmt::bytes(p.memory)
        } else {
            format!("{:.1}%", p.cpu)
        };
        if let RowAction::Kill(pid, name) = process_row(ui, c.icons, p, &value, c.width) {
            c.actions.push(Action::Kill(pid, name));
        }
    }
}

pub fn cpu(ui: &mut egui::Ui, c: &mut Ctx) {
    let s = c.snap;
    let color = c.color(Section::Cpu);
    header(ui, c, Section::Cpu, |ui| {
        ui.label(
            RichText::new(fmt::percent(s.cpu.total))
                .font(FontId::monospace(14.0))
                .color(color),
        );
    });
    if !s.cpu.model.is_empty() {
        ui.add(egui::Label::new(RichText::new(&s.cpu.model).size(10.5).color(secondary(ui))).truncate());
    }
    widgets::sparkline(
        ui,
        Vec2::new(c.width, 44.0),
        &c.hist.cpu.values(),
        Some(100.0),
        color,
    );
    ui.add_space(2.0);
    stat_pair(
        ui,
        c.width,
        |ui| stat(ui, None, &t("User"), &fmt::percent(s.cpu.user), None),
        |ui| stat(ui, None, &t("System"), &fmt::percent(s.cpu.system), None),
    );
    stat_pair(
        ui,
        c.width,
        |ui| {
            stat(
                ui,
                None,
                &t("Idle"),
                &fmt::percent((100.0 - s.cpu.total).max(0.0)),
                None,
            )
        },
        |ui| {
            let v = s
                .cpu
                .frequency_mhz
                .map(|m| format!("{:.2} GHz", m as f64 / 1000.0))
                .unwrap_or_else(|| "—".into());
            stat(ui, None, &t("Speed"), &v, None)
        },
    );
    if let Some(l) = s.cpu.load {
        section_label(ui, &t("Load Average"));
        ui.label(
            RichText::new(format!("{:.2}   {:.2}   {:.2}", l[0], l[1], l[2])).font(FontId::monospace(12.0)),
        );
    }
    // Per-core bars (two columns).
    section_label(
        ui,
        &if s.cpu.efficiency_cores > 0 {
            tf(
                "%lld cores (%lld performance · %lld efficiency) · %lld threads",
                &[
                    &s.cpu.physical_cores,
                    &s.cpu.performance_cores,
                    &s.cpu.efficiency_cores,
                    &s.cpu.logical_cores,
                ],
            )
        } else {
            tf(
                "%lld cores · %lld threads",
                &[&s.cpu.physical_cores, &s.cpu.logical_cores],
            )
        },
    );
    core_grid(ui, c.width, &s.cpu.cores, color, c.settings.colorize_utilization);
    if let Some(perf) = s.cpu.performance_pct {
        if s.thermal.throttling {
            ui.add_space(2.0);
            ui.horizontal(|ui| {
                theme::icon(ui, Icon::Warning, 11.0, theme::ORANGE);
                ui.label(
                    RichText::new(tf(
                        "Running at %lld%% of base clock under load",
                        &[&(perf as i64)],
                    ))
                    .size(10.5)
                    .color(theme::ORANGE),
                );
            });
        }
    }
    divider(ui);
    processes(ui, c, false);
}

/// Per-core load as a compact painted grid (columns of thin bars with the % beside each).
fn core_grid(ui: &mut egui::Ui, width: f32, cores: &[f64], color: egui::Color32, colorize: bool) {
    let cols = if cores.len() > 16 {
        4
    } else if cores.len() > 6 {
        2
    } else {
        1
    };
    let rows = cores.len().div_ceil(cols);
    let row_h = 11.0;
    let gap = 10.0;
    let colw = (width - gap * (cols - 1) as f32) / cols as f32;
    let (rect, _) = ui.allocate_exact_size(Vec2::new(width, rows as f32 * row_h), egui::Sense::hover());
    let p = ui.painter();
    let track = if ui.visuals().dark_mode {
        egui::Color32::from_white_alpha(28)
    } else {
        egui::Color32::from_black_alpha(22)
    };
    let weak = secondary(ui);
    for (i, v) in cores.iter().enumerate() {
        let (col, row) = (i / rows, i % rows);
        let x = rect.left() + col as f32 * (colw + gap);
        let y = rect.top() + row as f32 * row_h + row_h / 2.0;
        let bar_w = colw - 30.0;
        let bar = egui::Rect::from_min_size(egui::pos2(x, y - 2.0), Vec2::new(bar_w, 4.0));
        p.rect_filled(bar, 2.0, track);
        let f = (*v / 100.0).clamp(0.0, 1.0) as f32;
        if f > 0.0 {
            let mut fill = bar;
            fill.set_width((bar_w * f).max(4.0));
            p.rect_filled(fill, 2.0, if colorize { theme::load_color(*v) } else { color });
        }
        p.text(
            egui::pos2(x + colw, y),
            egui::Align2::RIGHT_CENTER,
            format!("{v:.0}%"),
            FontId::monospace(9.0),
            weak,
        );
    }
}

pub fn memory(ui: &mut egui::Ui, c: &mut Ctx) {
    let s = c.snap;
    let m = &s.memory;
    let color = c.color(Section::Memory);
    header(ui, c, Section::Memory, |ui| {
        ui.label(
            RichText::new(fmt::percent(m.usage_pct()))
                .font(FontId::monospace(14.0))
                .color(color),
        );
    });
    widgets::sparkline(
        ui,
        Vec2::new(c.width, 44.0),
        &c.hist.memory.values(),
        Some(100.0),
        color,
    );
    stat_pair(
        ui,
        c.width,
        |ui| stat(ui, None, &t("Used"), &fmt::bytes(m.used), None),
        |ui| stat(ui, None, &t("Total"), &fmt::bytes(m.total), None),
    );
    stat_pair(
        ui,
        c.width,
        |ui| stat(ui, None, &t("Available"), &fmt::bytes(m.available), None),
        |ui| stat(ui, None, &t("Cached"), &fmt::bytes(m.cached), None),
    );
    section_label(ui, &t("Pressure"));
    let (pc, word) = match m.pressure {
        0 => (theme::GREEN, t("Normal")),
        1 => (theme::YELLOW, t("Warning")),
        _ => (theme::RED, t("Critical")),
    };
    ui.horizontal(|ui| {
        widgets::usage_bar(ui, c.width - 70.0, 6.0, m.usage_pct(), pc);
        ui.label(RichText::new(word).size(11.0).color(pc));
    });
    if m.commit_limit > 0 {
        section_label(ui, &t("Committed"));
        ui.horizontal(|ui| {
            widgets::usage_bar(ui, c.width - 120.0, 6.0, m.commit_pct(), color);
            ui.label(
                RichText::new(format!(
                    "{} / {}",
                    fmt::bytes(m.committed),
                    fmt::bytes(m.commit_limit)
                ))
                .font(FontId::monospace(10.5)),
            );
        });
    }
    widgets::kv(
        ui,
        &t("Page file used"),
        &format!("{} / {}", fmt::bytes(m.swap_used), fmt::bytes(m.swap_total)),
    );
    if let Some(v) = m.compressed {
        widgets::kv(ui, &t("Compressed"), &fmt::bytes(v));
    }
    if let (Some(pp), Some(np)) = (m.paged_pool, m.nonpaged_pool) {
        widgets::kv(
            ui,
            &t("Paged / non-paged pool"),
            &format!("{} / {}", fmt::bytes(pp), fmt::bytes(np)),
        );
    }
    divider(ui);
    processes(ui, c, true);
}

pub fn gpu(ui: &mut egui::Ui, c: &mut Ctx) {
    let s = c.snap;
    let g = &s.gpu;
    let color = c.color(Section::Gpu);
    header(ui, c, Section::Gpu, |ui| {
        if g.available {
            ui.label(
                RichText::new(fmt::percent(g.utilization))
                    .font(FontId::monospace(14.0))
                    .color(color),
            );
        }
    });
    if !g.available {
        ui.label(RichText::new(t("GPU counters aren't available on this PC.")).color(secondary(ui)));
        return;
    }
    ui.add(egui::Label::new(RichText::new(&g.name).size(11.0)).truncate());
    widgets::sparkline(
        ui,
        Vec2::new(c.width, 44.0),
        &c.hist.gpu.values(),
        Some(100.0),
        color,
    );
    if let (Some(u), Some(tot)) = (g.dedicated_used, g.dedicated_total) {
        section_label(ui, &t("Dedicated memory"));
        ui.horizontal(|ui| {
            widgets::usage_bar(ui, c.width - 120.0, 6.0, u as f64 / tot as f64 * 100.0, color);
            ui.label(
                RichText::new(format!("{} / {}", fmt::bytes(u), fmt::bytes(tot)))
                    .font(FontId::monospace(10.5)),
            );
        });
    }
    if let Some(sh) = g.shared_used {
        widgets::kv(ui, &t("Shared memory"), &fmt::bytes(sh));
    }
    if let Some(tc) = g.temperature_c {
        widgets::kv(ui, &t("Temperature"), &fmt::temperature(tc));
    }
    if !g.engines.is_empty() {
        section_label(ui, &t("Engines"));
        for (name, v) in g.engines.iter().take(6) {
            ui.horizontal(|ui| {
                ui.allocate_ui(Vec2::new(100.0, 14.0), |ui| {
                    ui.set_width(100.0);
                    ui.label(RichText::new(name).size(11.0));
                });
                widgets::usage_bar(ui, c.width - 150.0, 5.0, *v, color);
                ui.label(
                    RichText::new(fmt::percent(*v))
                        .font(FontId::monospace(10.5))
                        .color(secondary(ui)),
                );
            });
        }
    }
}

pub fn thermal_color(l: ThermalLevel) -> Color32 {
    match l {
        ThermalLevel::Nominal => theme::GREEN,
        ThermalLevel::Fair => theme::YELLOW,
        ThermalLevel::Serious => theme::ORANGE,
        ThermalLevel::Critical => theme::RED,
    }
}

pub fn thermal(ui: &mut egui::Ui, c: &mut Ctx) {
    let s = c.snap;
    let th = &s.thermal;
    header(ui, c, Section::Thermal, |ui| {
        ui.label(
            RichText::new(t(th.level.english()))
                .font(FontId::monospace(13.0))
                .color(thermal_color(th.level)),
        );
    });
    if let Some(perf) = s.cpu.performance_pct {
        let col = if th.throttling {
            theme::ORANGE
        } else {
            theme::GREEN
        };
        widgets::kv_colored(ui, &t("CPU clock vs base"), &fmt::percent(perf), col);
        if th.throttling {
            ui.label(
                RichText::new(t(
                    "The CPU is slowing itself down under load — heat or power limits.",
                ))
                .size(10.5)
                .color(theme::ORANGE),
            );
        }
    }
    section_label(ui, &t("Temperatures"));
    let mut any = false;
    for (name, tc) in &th.zones {
        widgets::kv(
            ui,
            &format!("{} ({})", t("Thermal zone"), name),
            &fmt::temperature(*tc),
        );
        any = true;
    }
    if let Some(g) = s.gpu.temperature_c {
        widgets::kv(ui, &t("GPU"), &fmt::temperature(g));
        any = true;
    }
    for d in &s.disk.drives {
        if let Some(tc) = d.temperature_c {
            widgets::kv(ui, &d.name, &fmt::temperature(tc as f64));
            any = true;
        }
    }
    if let Some(bt) = s.battery.temperature_c {
        widgets::kv(ui, &t("Battery"), &fmt::temperature(bt));
        any = true;
    }
    if !any {
        ui.label(
            RichText::new(t("This PC doesn't report temperatures to standard users."))
                .size(10.5)
                .color(secondary(ui)),
        );
    }
    if !th.fans.is_empty() {
        section_label(ui, &t("Fans"));
        for f in &th.fans {
            ui.horizontal(|ui| {
                theme::icon(ui, Icon::Fan, 11.0, secondary(ui));
                ui.label(RichText::new(&f.name).size(11.0));
                widgets::usage_bar(
                    ui,
                    c.width - 110.0,
                    5.0,
                    f.rpm as f64,
                    theme::category_color(crate::theme::Category::Thermal),
                );
                ui.label(RichText::new(format!("{}%", f.rpm)).font(FontId::monospace(10.5)));
            });
        }
    }
    ui.add_space(4.0);
    ui.label(
        RichText::new(t("Windows keeps CPU sensors and fan speeds behind kernel drivers; Blip shows what it can read without admin rights."))
            .size(10.0)
            .color(theme::tertiary(ui)),
    );
}

pub fn battery(ui: &mut egui::Ui, c: &mut Ctx) {
    let b = &c.snap.battery;
    let color = if b.level <= 20.0 {
        theme::RED
    } else {
        c.color(Section::Battery)
    };
    header(ui, c, Section::Battery, |ui| {
        if b.present {
            ui.label(
                RichText::new(fmt::percent(b.level))
                    .font(FontId::monospace(14.0))
                    .color(color),
            );
        }
    });
    if !b.present {
        ui.label(RichText::new(t("No battery detected")).color(secondary(ui)));
        return;
    }
    widgets::usage_bar(ui, c.width, 8.0, b.level, color);
    ui.add_space(3.0);
    let status = if b.charging {
        t("Charging")
    } else if b.plugged_in {
        t("Plugged in, not charging")
    } else {
        t("On battery")
    };
    widgets::kv(ui, &t("Status"), &status);
    widgets::kv(
        ui,
        &t("Time remaining"),
        &b.minutes_remaining.map(fmt::minutes).unwrap_or_else(|| {
            if b.plugged_in {
                "—".into()
            } else {
                t("Calculating...")
            }
        }),
    );
    if let Some(h) = b.health_pct {
        let hc = if h < 80.0 { theme::ORANGE } else { theme::GREEN };
        widgets::kv_colored(ui, &t("Health"), &fmt::percent(h), hc);
    }
    if let (Some(d), Some(f)) = (b.design_capacity_mwh, b.full_capacity_mwh) {
        widgets::kv(
            ui,
            &t("Capacity (full / design)"),
            &format!("{:.1} / {:.1} Wh", f as f64 / 1000.0, d as f64 / 1000.0),
        );
    }
    if let Some(cy) = b.cycle_count {
        widgets::kv(ui, &t("Cycle Count"), &cy.to_string());
    }
    if let Some(tc) = b.temperature_c {
        widgets::kv(ui, &t("Temperature"), &fmt::temperature(tc));
    }
    if let Some(r) = b.rate_mw.filter(|r| *r != 0) {
        let label = if r > 0 {
            t("Charging rate")
        } else {
            t("Power draw")
        };
        widgets::kv(ui, &label, &format!("{:.1} W", r.abs() as f64 / 1000.0));
    }
    if let Some(ch) = &b.chemistry {
        widgets::kv(ui, &t("Chemistry"), ch);
    }
    if b.battery_saver {
        widgets::kv_colored(ui, &t("Battery saver"), &t("On"), theme::YELLOW);
    }
}

pub fn awake(ui: &mut egui::Ui, c: &mut Ctx) {
    let session = c.app.awake();
    let color = c.color(Section::Awake);
    header(ui, c, Section::Awake, |ui| {
        let (txt, col) = if session.is_some() {
            (t("On"), theme::GREEN)
        } else {
            (t("Off"), secondary(ui))
        };
        ui.label(RichText::new(txt).font(FontId::monospace(13.0)).color(col));
    });
    ui.label(
        RichText::new(t(
            "Stops this PC from going to sleep, for a while or until you turn it off.",
        ))
        .size(10.5)
        .color(secondary(ui)),
    );
    ui.add_space(4.0);
    let mut settings = c.settings.clone();
    let mut changed = false;
    if let Some(s) = session {
        let until = match s.until {
            Some(u) => tf("Until %@", &[&crate::timefmt::time(u)]),
            None => t("Until turned off"),
        };
        ui.label(RichText::new(until).font(theme::bold(12.5)).color(color));
        ui.add_space(2.0);
        if ui.button(t("Turn Off")).clicked() {
            c.app.stop_awake();
        }
    } else {
        ui.horizontal_wrapped(|ui| {
            for (mins, label) in [
                (30, t("30 min")),
                (60, t("1 hour")),
                (120, t("2 hours")),
                (240, t("4 hours")),
                (0, t("Until off")),
            ] {
                if ui.button(label).clicked() {
                    settings.keep_awake_minutes = mins;
                    changed = true;
                    c.app.start_awake(
                        mins,
                        AwakeOptions {
                            keep_display_on: settings.keep_awake_display,
                            ignore_lid: settings.keep_awake_lid_closed
                                && blip_platform::KeepAwake::lid_supported(),
                            jiggle: settings.keep_awake_jiggle,
                        },
                    );
                }
            }
        });
    }
    divider(ui);
    changed |= ui
        .checkbox(&mut settings.keep_awake_display, t("Keep the display on"))
        .changed();
    if blip_platform::KeepAwake::lid_supported() {
        changed |= ui
            .checkbox(
                &mut settings.keep_awake_lid_closed,
                t("Stay awake with the lid closed"),
            )
            .changed();
        ui.label(
            RichText::new(t("Sets the lid action to “Do nothing” while Keep Awake is on, and puts it back when it ends, when Blip quits, or at 10% battery."))
                .size(10.0)
                .color(theme::tertiary(ui)),
        );
    }
    changed |= ui
        .checkbox(&mut settings.keep_awake_jiggle, t("Jiggle the mouse when idle"))
        .changed();
    if let Some(e) = c.app.awake.lock().unwrap().last_error.clone() {
        ui.label(RichText::new(e).size(10.5).color(theme::ORANGE));
    }
    if changed {
        c.app.update_settings(|s| {
            s.keep_awake_minutes = settings.keep_awake_minutes;
            s.keep_awake_display = settings.keep_awake_display;
            s.keep_awake_lid_closed = settings.keep_awake_lid_closed;
            s.keep_awake_jiggle = settings.keep_awake_jiggle;
        });
        // Options changed mid-session: re-engage with the new ones, same end time.
        if let Some(s) = c.app.awake() {
            let remaining = s
                .until
                .and_then(|u| u.duration_since(std::time::SystemTime::now()).ok())
                .map(|d| (d.as_secs() / 60).max(1) as u32)
                .unwrap_or(0);
            c.app.start_awake(
                remaining,
                AwakeOptions {
                    keep_display_on: settings.keep_awake_display,
                    ignore_lid: settings.keep_awake_lid_closed && blip_platform::KeepAwake::lid_supported(),
                    jiggle: settings.keep_awake_jiggle,
                },
            );
        }
    }
}
