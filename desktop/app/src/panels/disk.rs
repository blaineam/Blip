//! Disk: volumes (with a one-click speed test each), live I/O, drive health, speed test.

use eframe::egui::{self, FontId, RichText, Vec2};

use blip_core::disktest::DiskPhase;
use blip_core::{fmt, t, tf, Icon};

use super::{divider, header, section_label, Ctx};
use crate::sections::Section;
use crate::theme::{self, secondary};
use crate::widgets::{self, stat, stat_pair};

pub fn show(ui: &mut egui::Ui, c: &mut Ctx) {
    let s = c.snap;
    let color = c.color(Section::Disk);
    let dstate = c.app.disk.state();
    header(ui, c, Section::Disk, |ui| {
        if let Some(v) = s.disk.system_volume() {
            ui.label(
                RichText::new(fmt::percent(v.usage_pct()))
                    .font(FontId::monospace(14.0))
                    .color(color),
            );
        }
    });

    for v in &s.disk.volumes {
        ui.horizontal(|ui| {
            theme::icon(ui, Icon::Disk, 11.0, color);
            let name = if v.name.is_empty() || v.name == v.mount {
                v.mount.clone()
            } else {
                format!("{} ({})", v.name, v.mount.trim_end_matches('\\'))
            };
            ui.add(egui::Label::new(RichText::new(name).size(11.5)).truncate());
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let tip = tf("Run a speed test on %@", &[&v.mount]);
                if !dstate.running && theme::icon_button(ui, Icon::Speed, 11.0, secondary(ui), &tip).clicked()
                {
                    let dir = crate::state::folder_on_volume(&v.mount);
                    c.app.disk.start(c.settings.disk_speed_size, dir, v.mount.clone());
                }
                ui.label(
                    RichText::new(tf("%@ free", &[&fmt::disk_bytes(v.free)]))
                        .size(10.5)
                        .color(secondary(ui)),
                );
            });
        });
        widgets::usage_bar(
            ui,
            c.width,
            5.0,
            v.usage_pct(),
            if c.settings.colorize_utilization {
                theme::load_color(v.usage_pct())
            } else {
                color
            },
        );
        ui.add_space(2.0);
    }

    divider(ui);
    stat_pair(
        ui,
        c.width,
        |ui| {
            stat(
                ui,
                Some((Icon::Down, theme::BLUE)),
                &t("Read"),
                &fmt::speed(s.disk.read_bps),
                None,
            )
        },
        |ui| {
            stat(
                ui,
                Some((Icon::Up, theme::ORANGE)),
                &t("Write"),
                &fmt::speed(s.disk.write_bps),
                None,
            )
        },
    );
    stat_pair(
        ui,
        c.width,
        |ui| {
            stat(
                ui,
                None,
                &t("Data Read"),
                &fmt::total_bytes(s.disk.total_read),
                None,
            )
        },
        |ui| {
            stat(
                ui,
                None,
                &t("Data Written"),
                &fmt::total_bytes(s.disk.total_written),
                None,
            )
        },
    );
    if let Some(a) = s.disk.active_pct {
        widgets::kv(ui, &t("Active time"), &fmt::percent(a));
    }
    section_label(ui, &t("I/O over time"));
    widgets::dual_chart(
        ui,
        c.width,
        60.0,
        (&c.hist.disk_read.values(), theme::BLUE, &t("Read")),
        (&c.hist.disk_write.values(), theme::ORANGE, &t("Write")),
        fmt::chart_speed,
    );

    if !s.disk.drives.is_empty() {
        divider(ui);
        section_label(ui, &t("Drive Health"));
        for d in &s.disk.drives {
            ui.horizontal(|ui| {
                let (ic, col) = if d.is_healthy() {
                    (Icon::Check, theme::GREEN)
                } else {
                    (Icon::Warning, theme::RED)
                };
                theme::icon(ui, ic, 11.0, col);
                ui.add(egui::Label::new(RichText::new(&d.name).font(theme::bold(11.5))).truncate());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let tag = [d.bus.as_str(), d.media.as_str()]
                        .iter()
                        .filter(|s| !s.is_empty())
                        .copied()
                        .collect::<Vec<_>>()
                        .join(" · ");
                    ui.label(RichText::new(tag).size(10.0).color(secondary(ui)));
                });
            });
            if let Some(life) = d.life_remaining() {
                let lc = if life < 20 {
                    theme::RED
                } else if life < 50 {
                    theme::ORANGE
                } else {
                    theme::GREEN
                };
                ui.horizontal(|ui| {
                    ui.label(RichText::new(t("Life Remaining")).size(11.0).color(secondary(ui)));
                    widgets::usage_bar(ui, c.width - 150.0, 5.0, life as f64, lc);
                    ui.label(
                        RichText::new(format!("{life}%"))
                            .font(FontId::monospace(11.0))
                            .color(lc),
                    );
                });
            }
            if !d.smart_status.is_empty() {
                widgets::kv(ui, "S.M.A.R.T.", &t(&d.smart_status));
            }
            if let (Some(sp), Some(th)) = (d.available_spare, d.available_spare_threshold) {
                widgets::kv(ui, &t("Available Spare"), &format!("{sp}% (≥ {th}%)"));
            }
            if let Some(tc) = d.temperature_c {
                widgets::kv(ui, &t("Temperature"), &fmt::temperature(tc as f64));
            }
            if let Some(w) = d.bytes_written {
                widgets::kv(ui, &t("Written (lifetime)"), &fmt::total_bytes(w));
            }
            if let Some(r) = d.bytes_read {
                widgets::kv(ui, &t("Read (lifetime)"), &fmt::total_bytes(r));
            }
            if let Some(h) = d.power_on_hours {
                widgets::kv(ui, &t("Power-On Hours"), &format!("{h} h"));
            }
            if let Some(pc) = d.power_cycles {
                widgets::kv(ui, &t("Power Cycles"), &pc.to_string());
            }
            if let Some(u) = d.unsafe_shutdowns {
                widgets::kv(ui, &t("Unsafe Shutdowns"), &u.to_string());
            }
            if let Some(m) = d.media_errors.filter(|m| *m > 0) {
                widgets::kv_colored(ui, &t("Media Errors"), &m.to_string(), theme::RED);
            }
            ui.add_space(3.0);
        }
    }

    divider(ui);
    let mut open = c.settings.disk_speed_expanded;
    if widgets::disclosure(ui, Icon::Speed, color, &t("Speed Test"), &mut open) {
        c.app.update_settings(|s| s.disk_speed_expanded = open);
    }
    if !open {
        return;
    }
    ui.horizontal(|ui| {
        ui.label(RichText::new(t("Size")).size(11.0).color(secondary(ui)));
        for mb in [128u32, 512, 1024] {
            if ui
                .selectable_label(c.settings.disk_speed_size == mb, format!("{mb} MB"))
                .clicked()
            {
                c.app.update_settings(|s| s.disk_speed_size = mb);
            }
        }
    });
    let (target_dir, target_label) = crate::state::disk_target(c.settings, c.snap);
    ui.horizontal(|ui| {
        theme::icon(ui, Icon::Folder, 11.0, secondary(ui));
        ui.add(egui::Label::new(RichText::new(&target_label).size(11.0)).truncate());
    });
    if dstate.running {
        let phase = match dstate.phase {
            DiskPhase::Writing => t("Writing…"),
            DiskPhase::Reading => t("Reading…"),
            DiskPhase::RandomRead => t("Random reads…"),
            DiskPhase::Idle => t("Starting…"),
        };
        ui.horizontal(|ui| {
            ui.spinner();
            ui.label(RichText::new(format!("{phase} {}", dstate.target_label)).size(11.0));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button(t("Cancel")).clicked() {
                    c.app.disk.cancel();
                }
            });
        });
        widgets::progress(ui, c.width, dstate.progress, color);
    } else if ui
        .add(
            egui::Button::new(RichText::new(format!("▶  {}", t("Run Test"))).color(theme::BLUE)).frame(false),
        )
        .clicked()
    {
        c.app
            .disk
            .start(c.settings.disk_speed_size, target_dir, target_label);
    }
    if let Some(e) = &dstate.last_error {
        ui.label(RichText::new(e).size(10.5).color(theme::RED));
    }
    if let Some(r) = &dstate.last_result {
        stat_pair(
            ui,
            c.width,
            |ui| {
                stat(
                    ui,
                    Some((Icon::Up, theme::ORANGE)),
                    &t("Write"),
                    &format!("{:.0} MB/s", r.write_mbps),
                    None,
                )
            },
            |ui| {
                stat(
                    ui,
                    Some((Icon::Down, theme::BLUE)),
                    &t("Read"),
                    &format!("{:.0} MB/s", r.read_mbps),
                    None,
                )
            },
        );
        if let Some(iops) = r.random_read_iops {
            widgets::kv(ui, &t("Random 4K read"), &format!("{iops:.0} IOPS"));
        }
        ui.label(
            RichText::new(format!(
                "{} · {} MB · {}",
                r.target,
                r.size_mb,
                crate::timefmt::ago(r.timestamp)
            ))
            .size(10.0)
            .color(theme::tertiary(ui)),
        );
    }
    if dstate.history.len() > 1 {
        let w: Vec<f64> = dstate.history.iter().map(|r| r.write_mbps).collect();
        let rd: Vec<f64> = dstate.history.iter().map(|r| r.read_mbps).collect();
        widgets::dual_chart(
            ui,
            c.width,
            44.0,
            (&rd, theme::BLUE, &t("Read")),
            (&w, theme::ORANGE, &t("Write")),
            |v| format!("{v:.0} MB/s"),
        );
    }
    ui.horizontal(|ui| {
        let mut auto = c.settings.disk_speed_auto_run;
        if ui.checkbox(&mut auto, t("Test automatically")).changed() {
            c.app.update_settings(|s| s.disk_speed_auto_run = auto);
        }
        if auto {
            ui.label(
                RichText::new(tf("every %lld min", &[&c.settings.disk_speed_interval]))
                    .size(10.5)
                    .color(secondary(ui)),
            );
        }
    });
    let _ = Vec2::ZERO;
}
