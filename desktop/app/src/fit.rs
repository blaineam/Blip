//! Sizing a window to its content. A scroll area is never taller than the space it's laid out
//! in, which is the window's *current* height; measuring that way, a window can't grow. So the
//! content is laid out with the tallest height allowed, and the window is then resized to what
//! it actually used.

use eframe::egui;

/// Lays out `add` in a `width` × `max_height` area (whatever the window's size is right now) and
/// returns the height it used, capped at `max_height`.
pub fn height_for_content(
    ui: &mut egui::Ui,
    width: f32,
    max_height: f32,
    add: impl FnOnce(&mut egui::Ui),
) -> f32 {
    let area = egui::Rect::from_min_size(ui.cursor().min, egui::vec2(width, max_height));
    let used = ui
        .scope_builder(egui::UiBuilder::new().max_rect(area), |ui| {
            add(ui);
        })
        .response
        .rect;
    used.height().min(max_height)
}

#[cfg(test)]
mod tests {
    use super::*;
    use egui_kittest::Harness;
    use std::sync::{Arc, Mutex};

    /// 800 points of rows in a scroll area, inside a window only 200 tall.
    fn measure(max_height: f32) -> f32 {
        let out = Arc::new(Mutex::new(0.0));
        let seen = out.clone();
        let mut h = Harness::builder()
            .with_size(egui::vec2(260.0, 200.0))
            .build_ui(move |ui| {
                let used = height_for_content(ui, 240.0, max_height, |ui| {
                    egui::ScrollArea::vertical()
                        .max_height(max_height)
                        .auto_shrink([false, true])
                        .show(ui, |ui| {
                            ui.allocate_space(egui::vec2(200.0, 800.0));
                        });
                });
                *seen.lock().unwrap() = used;
            });
        h.run_steps(3);
        let v = *out.lock().unwrap();
        v
    }

    #[test]
    fn grows_past_the_window_up_to_the_limit() {
        let tall = measure(1400.0);
        assert!((800.0..830.0).contains(&tall), "content height, got {tall}");
        let capped = measure(500.0);
        assert!((480.0..=500.0).contains(&capped), "screen limit, got {capped}");
    }
}
