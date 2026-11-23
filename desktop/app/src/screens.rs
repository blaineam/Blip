//! Offscreen renders of the popover and every panel (wgpu, no window). Writes PNGs to
//! `$BLIP_SHOTS_DIR` when set; always checks that nothing panics while drawing.

use eframe::egui;
use egui_kittest::Harness;

use crate::panels::{self, GeoCache};
use crate::sections::ALL;
use crate::state::Shared;
use crate::widgets::IconCache;

fn save(h: &mut Harness, name: &str) {
    let Ok(dir) = std::env::var("BLIP_SHOTS_DIR") else {
        return;
    };
    if let Ok(img) = h.render() {
        let _ = std::fs::create_dir_all(&dir);
        img.save(format!("{dir}/{name}.png")).expect("save png");
    }
}

fn setup(ctx: &egui::Context, dark: bool) {
    crate::theme::install_fonts(ctx);
    crate::theme::install_styles(ctx);
    ctx.set_theme(if dark {
        egui::Theme::Dark
    } else {
        egui::Theme::Light
    });
}

#[test]
fn render_popover_and_panels() {
    let app = Shared::new();
    {
        let mut live = app.live.write().unwrap();
        live.snapshot = crate::demo::snapshot();
        live.history = crate::demo::histories();
        live.samples = 60;
    }
    for dark in [true, false] {
        let suffix = if dark { "dark" } else { "light" };
        let snap = app.snapshot();
        let settings = app.settings();
        let a = app.clone();
        let mut h = Harness::builder()
            .with_size(egui::vec2(260.0, 460.0))
            .with_pixels_per_point(2.0)
            .build_ui(move |ui| {
                setup(ui.ctx(), dark);
                egui::Frame::new()
                    .fill(ui.visuals().panel_fill)
                    .inner_margin(egui::Margin::symmetric(0, 6))
                    .show(ui, |ui| {
                        ui.set_width(260.0);
                        crate::popover::show(
                            ui,
                            &a,
                            &snap,
                            &settings,
                            Some(crate::sections::Section::Cpu),
                            &mut |_, _| {},
                        );
                    });
            });
        h.run();
        save(&mut h, &format!("popover-{suffix}"));

        for sec in ALL {
            let a = app.clone();
            let mut icons = IconCache::default();
            let mut geo = GeoCache::default();
            let mut h = Harness::builder()
                .with_size(egui::vec2(324.0, 900.0))
                .with_pixels_per_point(2.0)
                .build_ui(move |ui| {
                    setup(ui.ctx(), dark);
                    let snap = a.snapshot();
                    let hist = a.live.read().unwrap().history.clone();
                    let settings = a.settings();
                    let mut actions = Vec::new();
                    egui::Frame::new()
                        .fill(ui.visuals().panel_fill)
                        .inner_margin(12.0)
                        .show(ui, |ui| {
                            let mut c = panels::Ctx {
                                app: &a,
                                snap: &snap,
                                hist: &hist,
                                settings: &settings,
                                icons: &mut icons,
                                geo: &mut geo,
                                actions: &mut actions,
                                width: panels::WIDTH,
                                detached: false,
                            };
                            panels::show(ui, sec, &mut c);
                        });
                });
            h.run();
            save(&mut h, &format!("panel-{}-{suffix}", sec.key()));
        }
    }
}
