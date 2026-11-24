//! The Settings window. Text fields live here (hover panels can't take keyboard focus on the
//! Mac, and Blip keeps the same split on Windows).

use eframe::egui::{self, RichText, Vec2};

use blip_core::geoip::GeoStatus;
use blip_core::settings::{DetailStyle, Settings, SpeedServerKind, ThemeChoice, TrayStyle};
use blip_core::{t, tf};

use crate::state::App;
use crate::theme::{self, secondary, tertiary};

#[derive(Default)]
pub struct Drafts {
    ping: Option<String>,
    trace: Option<String>,
    url: Option<String>,
    color: Option<String>,
    error: Option<String>,
    autostart_error: Option<String>,
}

fn group(ui: &mut egui::Ui, title: &str, body: impl FnOnce(&mut egui::Ui)) {
    ui.add_space(10.0);
    ui.label(RichText::new(title).font(theme::bold(13.0)));
    ui.add_space(2.0);
    egui::Frame::group(ui.style())
        .corner_radius(8.0)
        .inner_margin(10.0)
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            body(ui);
        });
}

fn note(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).size(10.5).color(tertiary(ui)));
}

pub fn show(ui: &mut egui::Ui, app: &App, drafts: &mut Drafts) {
    let mut s: Settings = app.settings();
    let before = s.clone();
    egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            let (r, _) = ui.allocate_exact_size(Vec2::splat(28.0), egui::Sense::hover());
            let c = crate::tray::render_logo(false);
            let tex = ui.ctx().load_texture("logo", egui::ColorImage::from_rgba_unmultiplied([32, 32], &c.px), egui::TextureOptions::LINEAR);
            ui.painter().image(tex.id(), r, egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)), egui::Color32::WHITE);
            ui.vertical(|ui| {
                ui.label(RichText::new("Blip").font(theme::bold(18.0)));
                ui.label(RichText::new(format!("v{}", crate::VERSION)).size(10.5).color(secondary(ui)));
            });
        });

        group(ui, &t("General"), |ui| {
            let mut login = blip_platform::launch_at_login();
            if ui.checkbox(&mut login, t("Launch at login")).changed() {
                drafts.autostart_error = blip_platform::set_launch_at_login(login).err();
                s.launch_at_login = login;
            }
            if let Some(e) = &drafts.autostart_error {
                ui.label(RichText::new(e).size(10.5).color(theme::RED));
            }
            // Running the downloaded exe: offer the per-user install (Start menu, Settings › Apps,
            // blip-cli on PATH).
            #[cfg(windows)]
            if !crate::install::is_installed_copy() && ui.button(t("Install Blip…")).clicked() && crate::install::install_from_settings() {
                crate::QUIT_REQUESTED.store(true, std::sync::atomic::Ordering::Relaxed);
            }
            ui.horizontal(|ui| {
                ui.label(t("Appearance"));
                for (v, l) in [(ThemeChoice::System, t("System")), (ThemeChoice::Light, t("Light")), (ThemeChoice::Dark, t("Dark"))] {
                    ui.selectable_value(&mut s.theme, v, l);
                }
            });
            ui.horizontal(|ui| {
                ui.label(t("Language"));
                let langs = [("", t("System")), ("en", "English".into()), ("de", "Deutsch".into()), ("es", "Español".into()), ("fr", "Français".into()), ("it", "Italiano".into()), ("ja", "日本語".into()), ("ko", "한국어".into()), ("pt-BR", "Português (Brasil)".into()), ("zh-Hans", "简体中文".into())];
                let current = langs.iter().find(|(k, _)| *k == s.language).map(|(_, v)| v.clone()).unwrap_or_default();
                egui::ComboBox::from_id_salt("lang").selected_text(current).show_ui(ui, |ui| {
                    for (k, v) in &langs {
                        ui.selectable_value(&mut s.language, k.to_string(), v.as_str());
                    }
                });
            });
            ui.horizontal(|ui| {
                ui.label(t("Update every"));
                let mut secs = s.update_interval_secs as i32;
                if ui.add(egui::Slider::new(&mut secs, 1..=10).suffix(" s")).changed() {
                    s.update_interval_secs = secs as u64;
                }
            });
        });

        group(ui, &t("Notification area"), |ui| {
            ui.horizontal(|ui| {
                ui.label(t("Style"));
                ui.selectable_value(&mut s.tray_style, TrayStyle::Bars, t("Bars"));
                ui.selectable_value(&mut s.tray_style, TrayStyle::Numbers, t("Numbers"));
                ui.selectable_value(&mut s.tray_style, TrayStyle::Logo, t("Logo only"));
            });
            if s.tray_style != TrayStyle::Logo {
                ui.horizontal_wrapped(|ui| {
                    ui.checkbox(&mut s.show_cpu, t("CPU"));
                    ui.checkbox(&mut s.show_memory, t("Memory"));
                    ui.checkbox(&mut s.show_disk, t("Disk"));
                    ui.checkbox(&mut s.show_gpu, t("GPU"));
                    if s.tray_style == TrayStyle::Bars {
                        ui.checkbox(&mut s.show_network_dot, t("Network status dot"));
                    }
                });
            }
            if cfg!(target_os = "linux") {
                note(ui, &t("Tray icons need a desktop with a system tray. On GNOME, turn on the AppIndicator extension; without a tray, Blip opens as a window."));
            } else {
                note(ui, &t("Windows may tuck new icons into the overflow (^). Drag Blip onto the taskbar to keep it visible."));
            }
            ui.separator();
            ui.horizontal(|ui| {
                ui.label(t("Colors"));
                let mode = if s.accent_color_override.is_empty() { 0 } else if s.accent_color_override == "monochrome" { 1 } else { 2 };
                if ui.selectable_label(mode == 0, t("Category")).clicked() {
                    s.accent_color_override.clear();
                }
                if ui.selectable_label(mode == 1, t("Monochrome")).clicked() {
                    s.accent_color_override = "monochrome".into();
                }
                if ui.selectable_label(mode == 2, t("Custom")).clicked() && mode != 2 {
                    s.accent_color_override = "#0A84FF".into();
                }
                if mode == 2 {
                    let mut c = theme::parse_hex(&s.accent_color_override).unwrap_or(theme::BLUE);
                    if ui.color_edit_button_srgba(&mut c).changed() {
                        s.accent_color_override = format!("#{:02X}{:02X}{:02X}", c.r(), c.g(), c.b());
                    }
                }
            });
            ui.checkbox(&mut s.colorize_utilization, t("Color bars by utilization"));
            let _ = &mut drafts.color;
        });

        group(ui, &t("Popover"), |ui| {
            ui.horizontal(|ui| {
                ui.label(t("Details"));
                ui.selectable_value(&mut s.detail_panel_style, DetailStyle::Beside, t("Beside the menu (hover)"));
                ui.selectable_value(&mut s.detail_panel_style, DetailStyle::Inline, t("Inline (click)"));
            });
            ui.checkbox(&mut s.show_recommendations, t("Show suggestions"));
            if !s.dismissed_recommendations.is_empty() && ui.button(t("Restore dismissed suggestions")).clicked() {
                s.dismissed_recommendations.clear();
            }
        });

        group(ui, &t("Network"), |ui| {
            let ping = drafts.ping.get_or_insert_with(|| s.ping_target.clone());
            ui.horizontal(|ui| {
                ui.label(t("Ping target"));
                if ui.text_edit_singleline(ping).lost_focus() {
                    if blip_core::trace::is_valid_host(ping.trim()) {
                        s.ping_target = ping.trim().to_string();
                        drafts.error = None;
                    } else {
                        drafts.error = Some(tf("“%@” isn't a valid hostname or IP address.", &[&ping.trim()]));
                    }
                }
            });
            let trace = drafts.trace.get_or_insert_with(|| s.traceroute_target.clone());
            ui.horizontal(|ui| {
                ui.label(t("Traceroute target"));
                if ui.text_edit_singleline(trace).lost_focus() {
                    let v = trace.trim();
                    if v.is_empty() || blip_core::trace::is_valid_host(v) {
                        s.traceroute_target = v.to_string();
                        drafts.error = None;
                    } else {
                        drafts.error = Some(tf("“%@” isn't a valid hostname or IP address.", &[&v]));
                    }
                }
            });
            if let Some(e) = &drafts.error {
                ui.label(RichText::new(e).size(10.5).color(theme::RED));
            }
            ui.separator();
            ui.label(RichText::new(t("Speed Test")).strong());
            ui.horizontal(|ui| {
                ui.selectable_value(&mut s.speed_test_server_kind, SpeedServerKind::Public, t("OpenSpeedTest (public)"));
                ui.selectable_value(&mut s.speed_test_server_kind, SpeedServerKind::SelfHosted, t("Self-hosted"));
            });
            if s.speed_test_server_kind == SpeedServerKind::SelfHosted {
                let url = drafts.url.get_or_insert_with(|| s.speed_test_open_speed_test_url.clone());
                ui.horizontal(|ui| {
                    ui.label(t("Server"));
                    if ui.add(egui::TextEdit::singleline(url).hint_text("http://192.168.1.50:3000")).lost_focus() {
                        s.speed_test_open_speed_test_url = url.trim().to_string();
                    }
                });
                ui.checkbox(&mut s.net_speed_auto_run, t("Test automatically"));
                if s.net_speed_auto_run {
                    ui.horizontal(|ui| {
                        ui.label(t("Every"));
                        let mut m = s.net_speed_interval as i32;
                        if ui.add(egui::Slider::new(&mut m, 5..=1440).suffix(" min").logarithmic(true)).changed() {
                            s.net_speed_interval = m as u32;
                        }
                    });
                    note(ui, &t("Automatic tests skip metered connections."));
                }
            } else {
                note(ui, &t("The public test runs on OpenSpeedTest's donated servers, so it's manual-only. Self-host a server to test on a schedule."));
            }
            ui.horizontal(|ui| {
                if ui.link(t("Powered by OpenSpeedTest")).clicked() {
                    blip_platform::open("https://openspeedtest.com");
                }
                if ui.link(t("How to self-host")).clicked() {
                    blip_platform::open("https://openspeedtest.com/selfhosted-speedtest");
                }
            });
        });

        group(ui, &t("Disk"), |ui| {
            ui.horizontal(|ui| {
                ui.label(t("Test size"));
                for mb in [128u32, 512, 1024] {
                    ui.selectable_value(&mut s.disk_speed_size, mb, format!("{mb} MB"));
                }
            });
            ui.horizontal(|ui| {
                ui.label(t("Test location"));
                let label = if s.disk_speed_target.is_empty() { t("System drive") } else { s.disk_speed_target.clone() };
                ui.add(egui::Label::new(RichText::new(label).monospace()).truncate());
            });
            ui.horizontal(|ui| {
                if ui.button(t("Choose Folder…")).clicked() {
                    if let Some(p) = crate::shell::pick_folder() {
                        s.disk_speed_target = p;
                    }
                }
                if !s.disk_speed_target.is_empty() && ui.button(t("Use System Drive")).clicked() {
                    s.disk_speed_target.clear();
                }
            });
            ui.checkbox(&mut s.disk_speed_auto_run, t("Test automatically"));
            if s.disk_speed_auto_run {
                ui.horizontal(|ui| {
                    ui.label(t("Every"));
                    let mut m = s.disk_speed_interval as i32;
                    if ui.add(egui::Slider::new(&mut m, 5..=1440).suffix(" min").logarithmic(true)).changed() {
                        s.disk_speed_interval = m as u32;
                    }
                });
                note(ui, &t("Automatic tests skip drives below 30% life remaining."));
            }
        });

        group(ui, &t("Traceroute Map"), |ui| {
            note(ui, &t("Plots traceroute hops with DB-IP's free City Lite database, stored on this PC. Nothing is downloaded until you ask."));
            match app.geo.status() {
                GeoStatus::Absent => {
                    if ui.button(t("Download")).clicked() {
                        app.geo.download(app.repaint_fn());
                    }
                }
                GeoStatus::Downloading(p) => {
                    ui.horizontal(|ui| {
                        ui.spinner();
                        ui.label(if p >= 0.0 { tf("Downloading… %lld%%", &[&((p * 100.0) as i64)]) } else { t("Downloading…") });
                    });
                }
                GeoStatus::Ready { build_epoch, kind } => {
                    ui.label(tf("Installed — %@, %@", &[&kind, &crate::timefmt::short_date(build_epoch)]));
                    ui.horizontal(|ui| {
                        if ui.button(t("Update Now")).clicked() {
                            app.geo.download(app.repaint_fn());
                        }
                        if ui.button(t("Remove")).clicked() {
                            app.geo.remove();
                        }
                    });
                }
                GeoStatus::Failed(e) => {
                    ui.label(RichText::new(t(&e)).color(theme::RED));
                    if ui.button(t("Try Again")).clicked() {
                        app.geo.download(app.repaint_fn());
                    }
                }
            }
            ui.checkbox(&mut s.geoip_auto_update, t("Update automatically each month"));
            if ui.link(t("IP geolocation by DB-IP")).clicked() {
                blip_platform::open(blip_core::geoip::ATTRIBUTION_URL);
            }
        });

        group(ui, &t("Support Future Development"), |ui| {
            note(ui, &t("Blip is free and open source. If it's useful to you, you can chip in."));
            ui.horizontal_wrapped(|ui| {
                for (label, url) in [
                    ("GitHub Sponsors", "https://github.com/sponsors/blaineam"),
                    ("Ko-fi", "https://ko-fi.com/blaineam"),
                    ("wemiller.com/support", "https://wemiller.com/support"),
                ] {
                    if ui.link(label).clicked() {
                        blip_platform::open(url);
                    }
                }
            });
            ui.separator();
            ui.horizontal_wrapped(|ui| {
                if ui.link(t("Report an issue")).clicked() {
                    blip_platform::open("https://github.com/blaineam/blip/issues");
                }
                if ui.link(t("Source code")).clicked() {
                    blip_platform::open("https://github.com/blaineam/blip");
                }
                if ui.link(t("Open data folder")).clicked() {
                    let _ = std::fs::create_dir_all(blip_core::paths::data_dir());
                    blip_platform::open(&blip_core::paths::data_dir().display().to_string());
                }
            });
            note(ui, &t("Blip runs as you — no administrator rights, no drivers, no background service."));
        });
        ui.add_space(12.0);
    });
    if s != before {
        app.update_settings(|cur| *cur = s);
    }
}
