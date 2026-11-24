//! Network: throughput, latency, interfaces and addresses, WAN IP on request, the speed test
//! with connection grades, and live traceroute/MTR with an optional map.

use std::collections::HashMap;

use eframe::egui::{self, Color32, FontId, RichText, Vec2};

use blip_core::geoip::GeoPoint;
use blip_core::grades::Grade;
use blip_core::model::InterfaceKind;
use blip_core::settings::SpeedServerKind;
use blip_core::speedtest::SpeedPhase;
use blip_core::{fmt, t, tf, Icon};

use super::{divider, header, section_label, Ctx};
use crate::sections::Section;
use crate::theme::{self, secondary};
use crate::widgets::{self, stat, stat_pair};

#[derive(Default)]
pub struct GeoCache {
    map: HashMap<String, Option<GeoPoint>>,
}

impl GeoCache {
    pub fn get(&mut self, db: &blip_core::geoip::GeoDb, ip: &str) -> Option<GeoPoint> {
        if !blip_core::trace::is_public_ipv4(ip) || !db.is_ready() {
            return None;
        }
        self.map
            .entry(ip.to_string())
            .or_insert_with(|| db.lookup(ip))
            .clone()
    }
}

fn grade_color(g: Grade) -> Color32 {
    match g {
        Grade::A => theme::GREEN,
        Grade::B => theme::MINT,
        Grade::C => theme::ORANGE,
        Grade::F => theme::RED,
    }
}

pub fn show(ui: &mut egui::Ui, c: &mut Ctx) {
    let s = c.snap;
    let n = &s.network;
    header(ui, c, Section::Network, |ui| {
        let (r, _) = ui.allocate_exact_size(Vec2::splat(8.0), egui::Sense::hover());
        ui.painter().circle_filled(
            r.center(),
            3.5,
            if n.connected { theme::GREEN } else { theme::RED },
        );
    });
    stat_pair(
        ui,
        c.width,
        |ui| {
            stat(
                ui,
                Some((Icon::Down, theme::GREEN)),
                &t("Download"),
                &fmt::speed(n.down_bps),
                None,
            )
        },
        |ui| {
            stat(
                ui,
                Some((Icon::Up, theme::BLUE)),
                &t("Upload"),
                &fmt::speed(n.up_bps),
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
                &t("WAN Ping"),
                &fmt::ms(n.ping_ms),
                n.ping_ms.map(theme::ping_color),
            )
        },
        |ui| {
            stat(
                ui,
                None,
                &t("Router Ping"),
                &fmt::ms(n.router_ping_ms),
                n.router_ping_ms.map(theme::ping_color),
            )
        },
    );
    stat_pair(
        ui,
        c.width,
        |ui| stat(ui, None, &t("Total Down"), &fmt::total_bytes(n.total_down), None),
        |ui| stat(ui, None, &t("Total Up"), &fmt::total_bytes(n.total_up), None),
    );
    section_label(ui, &t("Bandwidth over time"));
    widgets::dual_chart(
        ui,
        c.width,
        60.0,
        (&c.hist.net_down.values(), theme::GREEN, &t("Down")),
        (&c.hist.net_up.values(), theme::BLUE, &t("Up")),
        fmt::chart_speed,
    );

    divider(ui);
    if let Some(p) = n.primary_interface() {
        widgets::kv(ui, &t("Interface"), &p.name);
        if let Some(ssid) = &p.ssid {
            let sig = p.signal_pct.map(|q| format!(" · {q}%")).unwrap_or_default();
            widgets::kv(ui, &t("Wi-Fi"), &format!("{ssid}{sig}"));
        }
        widgets::kv_copy(ui, &t("IPv4 (LAN)"), p.ipv4.first().map_or("—", |s| s.as_str()));
        if let Some(gw) = &n.router_ip {
            widgets::kv_copy(ui, &t("Router"), gw);
        }
        let v6 = p.ipv6.iter().find(|a| !a.starts_with("fe80")).or(p.ipv6.first());
        widgets::kv_copy(ui, &t("IPv6"), v6.map_or("—", |s| s.as_str()));
        if !p.mac.is_empty() {
            widgets::kv_copy(ui, &t("MAC Address"), &p.mac);
        }
        if let Some(sp) = p.link_speed_bps {
            widgets::kv(ui, &t("Link speed"), &fmt::throughput(sp as f64 / 1e6));
        }
        if !p.dns.is_empty() {
            widgets::kv_copy(
                ui,
                &t("DNS"),
                &p.dns.iter().take(2).cloned().collect::<Vec<_>>().join(", "),
            );
        }
    } else {
        ui.label(RichText::new(t("Not connected")).color(theme::RED));
    }
    if let Some(vpn) = n.interfaces.iter().find(|i| i.kind == InterfaceKind::Vpn) {
        ui.horizontal(|ui| {
            theme::icon(ui, Icon::Shield, 11.0, theme::GREEN);
            ui.label(
                RichText::new(tf("VPN: %@", &[&vpn.name]))
                    .size(11.0)
                    .color(theme::GREEN),
            );
        });
        if let Some(a) = vpn.ipv4.first() {
            widgets::kv_copy(ui, &t("VPN address"), a);
        }
    }
    if n.metered {
        widgets::kv_colored(ui, &t("Metered connection"), &t("On"), theme::YELLOW);
    }
    // WAN IP: fetched only when asked.
    let wan = c.app.wan_ip.lock().unwrap().clone();
    ui.horizontal(|ui| {
        ui.label(RichText::new(t("WAN IP")).size(11.5).color(secondary(ui)));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| match wan {
            Some(ip) => {
                if ui
                    .add(
                        egui::Label::new(RichText::new(&ip).font(FontId::monospace(11.5)))
                            .sense(egui::Sense::click()),
                    )
                    .on_hover_text(t("Copy"))
                    .clicked()
                {
                    ui.ctx().copy_text(ip);
                }
            }
            None => {
                if ui
                    .add(
                        egui::Label::new(RichText::new(t("Tap to reveal")).size(11.0).color(theme::BLUE))
                            .sense(egui::Sense::click()),
                    )
                    .clicked()
                {
                    let app = c.app.clone();
                    *app.wan_ip.lock().unwrap() = Some("…".into());
                    std::thread::spawn(move || {
                        let ip = blip_core::wan_ip().unwrap_or_else(|| t("Unavailable"));
                        *app.wan_ip.lock().unwrap() = Some(ip);
                        app.repaint();
                    });
                }
            }
        });
    });

    divider(ui);
    speed_test(ui, c);
    divider(ui);
    traceroute(ui, c);
}

fn speed_test(ui: &mut egui::Ui, c: &mut Ctx) {
    let color = theme::category_color(crate::theme::Category::Bench);
    let mut open = c.settings.net_speed_expanded;
    if widgets::disclosure(ui, Icon::Speed, color, &t("Speed Test"), &mut open) {
        c.app.update_settings(|s| s.net_speed_expanded = open);
    }
    if !open {
        return;
    }
    let st = c.app.speed.state();
    let kind = c.settings.speed_test_server_kind;
    ui.horizontal(|ui| {
        theme::icon(ui, Icon::Globe, 11.0, secondary(ui));
        egui::ComboBox::from_label(t("Server"))
            .selected_text(match kind {
                SpeedServerKind::Public => t("OpenSpeedTest (public)"),
                SpeedServerKind::SelfHosted => t("Self-hosted"),
            })
            .width(170.0)
            .show_ui(ui, |ui| {
                for (k, label) in [
                    (SpeedServerKind::Public, t("OpenSpeedTest (public)")),
                    (SpeedServerKind::SelfHosted, t("Self-hosted")),
                ] {
                    if ui.selectable_label(kind == k, label).clicked() {
                        c.app.update_settings(|s| s.speed_test_server_kind = k);
                    }
                }
            });
    });
    let self_hosted_base = blip_core::speedtest::normalize_base(&c.settings.speed_test_open_speed_test_url);
    match kind {
        SpeedServerKind::Public => {
            let note = if cfg!(windows) {
                t("Runs OpenSpeedTest's public test in the background and graphs the result here. Public infra — manual runs only.")
            } else {
                t("Opens OpenSpeedTest's public test in your browser. To graph results here, use a self-hosted server.")
            };
            ui.label(RichText::new(note).size(10.0).color(theme::tertiary(ui)));
        }
        SpeedServerKind::SelfHosted => match &self_hosted_base {
            Some(b) => {
                ui.label(RichText::new(b).size(10.5).color(secondary(ui)));
            }
            None => {
                if ui
                    .link(RichText::new(t("Set your server's address in Settings.")).size(10.5))
                    .clicked()
                {
                    c.actions.push(super::Action::OpenSettings);
                }
            }
        },
    }
    if st.phase.is_running() {
        let (label, col) = match st.phase {
            SpeedPhase::Latency => (t("Measuring latency…"), secondary(ui)),
            SpeedPhase::Upload => (t("Upload"), theme::BLUE),
            _ => (t("Download"), theme::GREEN),
        };
        ui.horizontal(|ui| {
            ui.spinner();
            ui.label(RichText::new(label).size(11.5).color(col));
            ui.label(RichText::new(fmt::throughput(st.live_mbps)).font(FontId::monospace(13.0)));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button(t("Cancel")).clicked() {
                    c.app.speed.cancel();
                    crate::publictest::cancel();
                }
            });
        });
        let max = st
            .down_curve
            .iter()
            .chain(st.up_curve.iter())
            .copied()
            .fold(1.0, f64::max);
        widgets::dual_chart(
            ui,
            c.width,
            50.0,
            (&st.down_curve, theme::GREEN, &t("Down")),
            (&st.up_curve, theme::BLUE, &t("Up")),
            |v| fmt::throughput(v.min(max * 2.0)),
        );
    } else {
        let can_run = kind == SpeedServerKind::Public || self_hosted_base.is_some();
        if ui
            .add_enabled(
                can_run,
                egui::Button::new(RichText::new(format!("▶  {}", t("Run Test"))).color(theme::BLUE))
                    .frame(false),
            )
            .clicked()
        {
            if kind == SpeedServerKind::Public && !cfg!(windows) {
                blip_platform::open("https://openspeedtest.com/?run");
            } else {
                c.app.start_speed_test();
            }
        }
    }
    if let SpeedPhase::Failed(msg) = &st.phase {
        ui.label(RichText::new(t(msg)).size(10.5).color(theme::RED));
    }
    if let Some(r) = &st.last_result {
        stat_pair(
            ui,
            c.width,
            |ui| {
                stat(
                    ui,
                    Some((Icon::Down, theme::GREEN)),
                    &t("Download"),
                    &fmt::throughput(r.down_mbps),
                    None,
                )
            },
            |ui| {
                stat(
                    ui,
                    Some((Icon::Up, theme::BLUE)),
                    &t("Upload"),
                    &r.up_mbps.map(fmt::throughput).unwrap_or_else(|| "—".into()),
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
                    &t("Ping (idle)"),
                    &fmt::ms(r.ping_ms),
                    r.ping_ms.map(theme::ping_color),
                )
            },
            |ui| {
                stat(
                    ui,
                    None,
                    &t("Ping (loaded)"),
                    &fmt::ms(r.loaded_ping_ms),
                    r.loaded_ping_ms.map(theme::ping_color),
                )
            },
        );
        let grades = blip_core::grades::evaluate(r.down_mbps, r.up_mbps, r.ping_ms, r.loaded_ping_ms);
        ui.horizontal_wrapped(|ui| {
            ui.spacing_mut().item_spacing = Vec2::new(4.0, 3.0);
            for g in &grades {
                let col = grade_color(g.grade);
                egui::Frame::new()
                    .fill(col.gamma_multiply(0.18))
                    .corner_radius(4.0)
                    .inner_margin(egui::Margin::symmetric(5, 1))
                    .show(ui, |ui| {
                        ui.label(
                            RichText::new(format!("{} {}", g.grade.letter(), g.name))
                                .size(10.0)
                                .color(col),
                        );
                    })
                    .response
                    .on_hover_text(g.grade.word());
            }
        });
        ui.label(
            RichText::new(crate::timefmt::ago(r.timestamp))
                .size(10.0)
                .color(theme::tertiary(ui)),
        );
    }
    if st.history.len() > 1 {
        let d: Vec<f64> = st.history.iter().map(|r| r.down_mbps).collect();
        let u: Vec<f64> = st.history.iter().map(|r| r.up_mbps.unwrap_or(0.0)).collect();
        section_label(ui, &t("History"));
        widgets::dual_chart(
            ui,
            c.width,
            40.0,
            (&d, theme::GREEN, &t("Down")),
            (&u, theme::BLUE, &t("Up")),
            fmt::throughput,
        );
    }
    if kind == SpeedServerKind::SelfHosted {
        ui.horizontal(|ui| {
            let mut auto = c.settings.net_speed_auto_run;
            if ui.checkbox(&mut auto, t("Test automatically")).changed() {
                c.app.update_settings(|s| s.net_speed_auto_run = auto);
            }
            if auto {
                ui.label(
                    RichText::new(tf("every %lld min", &[&c.settings.net_speed_interval]))
                        .size(10.5)
                        .color(secondary(ui)),
                );
            }
        });
        if c.settings.net_speed_auto_run && c.snap.network.metered {
            ui.label(
                RichText::new(t("Paused on metered connections."))
                    .size(10.0)
                    .color(theme::YELLOW),
            );
        }
    } else {
        ui.label(
            RichText::new(t("Want interval auto-run? Switch to a self-hosted server."))
                .size(10.0)
                .color(theme::tertiary(ui)),
        );
    }
    ui.horizontal(|ui| {
        if ui
            .link(RichText::new(t("Powered by OpenSpeedTest")).size(10.0))
            .clicked()
        {
            blip_platform::open("https://openspeedtest.com");
        }
        if ui
            .link(RichText::new(t("Self-host a server")).size(10.0))
            .clicked()
        {
            blip_platform::open("https://openspeedtest.com/selfhosted-speedtest");
        }
    });
}

fn traceroute(ui: &mut egui::Ui, c: &mut Ctx) {
    let color = c.color(Section::Network);
    let mut open = c.settings.trace_expanded;
    if widgets::disclosure(ui, Icon::Route, color, &t("Traceroute"), &mut open) {
        c.app.update_settings(|s| s.trace_expanded = open);
    }
    if !open {
        return;
    }
    let snap = c.app.trace.snapshot();
    let target = if c.settings.traceroute_target.is_empty() {
        c.settings.ping_target.clone()
    } else {
        c.settings.traceroute_target.clone()
    };
    ui.horizontal(|ui| {
        ui.label(RichText::new(t("Target")).size(11.0).color(secondary(ui)));
        ui.label(
            RichText::new(if snap.running || !snap.host.is_empty() {
                &snap.host
            } else {
                &target
            })
            .font(FontId::monospace(11.5)),
        );
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if snap.running {
                if ui.button(t("Stop")).clicked() {
                    c.app.trace.stop();
                }
            } else if ui.button(t("Start")).clicked() {
                let _ = c.app.trace.start(&target, c.app.repaint_fn());
            }
        });
    });
    ui.label(
        RichText::new(t("Change the target in Settings › Network."))
            .size(10.0)
            .color(theme::tertiary(ui)),
    );
    if let Some(e) = &snap.error {
        ui.label(RichText::new(e).size(10.5).color(theme::RED));
    }
    if !snap.hops.is_empty() {
        egui::Grid::new("hops")
            .num_columns(5)
            .spacing(Vec2::new(8.0, 1.0))
            .striped(true)
            .show(ui, |ui| {
                for h in ["#", &t("Host"), &t("Loss"), &t("Avg"), &t("Best")] {
                    ui.label(RichText::new(h).size(10.0).color(secondary(ui)));
                }
                ui.end_row();
                for h in &snap.hops {
                    ui.label(RichText::new(h.hop.to_string()).font(FontId::monospace(10.5)));
                    ui.add(egui::Label::new(RichText::new(&h.host).font(FontId::monospace(10.5))).truncate());
                    let lc = if h.loss_pct >= 50.0 {
                        theme::RED
                    } else if h.loss_pct > 0.0 {
                        theme::ORANGE
                    } else {
                        theme::GREEN
                    };
                    ui.label(
                        RichText::new(format!("{:.0}%", h.loss_pct))
                            .font(FontId::monospace(10.5))
                            .color(lc),
                    );
                    ui.label(
                        RichText::new(h.avg_ms.map(|v| format!("{v:.0}")).unwrap_or_else(|| "—".into()))
                            .font(FontId::monospace(10.5)),
                    );
                    ui.label(
                        RichText::new(h.best_ms.map(|v| format!("{v:.0}")).unwrap_or_else(|| "—".into()))
                            .font(FontId::monospace(10.5)),
                    );
                    ui.end_row();
                }
            });
        ui.label(
            RichText::new(tf("%lld passes", &[&snap.passes]))
                .size(10.0)
                .color(theme::tertiary(ui)),
        );
        let mut map_open = c.settings.trace_map_shown;
        if widgets::disclosure(ui, Icon::Map, color, &t("Map"), &mut map_open) {
            c.app.update_settings(|s| s.trace_map_shown = map_open);
        }
        if map_open {
            super::map::show(ui, c, &snap.hops);
        }
    }
}
