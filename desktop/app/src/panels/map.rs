//! Traceroute map: hops geolocated with the optional offline DB-IP database, drawn over a
//! Natural Earth 1:110m coastline (public domain, 20 KB embedded) in an equirectangular view
//! fitted to the route. Scroll to zoom, drag to pan.

use std::sync::OnceLock;

use eframe::egui::{self, Align2, Color32, FontId, Pos2, Rect, RichText, Sense, Stroke, Vec2};
use eframe::epaint::{PathShape, PathStroke};

use blip_core::trace::HopStats;
use blip_core::{t, tf};

use super::Ctx;
use crate::theme::{self, secondary};

static WORLD: &[u8] = include_bytes!("../../res/world-110m.bin");

fn rings() -> &'static Vec<Vec<(f32, f32)>> {
    static R: OnceLock<Vec<Vec<(f32, f32)>>> = OnceLock::new();
    R.get_or_init(|| {
        let rd = |o: usize| u16::from_le_bytes([WORLD[o], WORLD[o + 1]]);
        let mut out = Vec::new();
        let n = rd(0) as usize;
        let mut o = 2;
        for _ in 0..n {
            let len = rd(o) as usize;
            o += 2;
            let mut ring = Vec::with_capacity(len);
            for _ in 0..len {
                let lon = i16::from_le_bytes([WORLD[o], WORLD[o + 1]]) as f32 / 100.0;
                let lat = i16::from_le_bytes([WORLD[o + 2], WORLD[o + 3]]) as f32 / 100.0;
                ring.push((lon, lat));
                o += 4;
            }
            out.push(ring);
        }
        out
    })
}

#[derive(Clone, Copy)]
struct View {
    center: (f32, f32),
    span_lon: f32,
}

pub fn show(ui: &mut egui::Ui, c: &mut Ctx, hops: &[HopStats]) {
    let geo = &c.app.geo;
    if !geo.is_ready() {
        ui.label(
            RichText::new(t("The map needs the free offline GeoIP database (about 130 MB)."))
                .size(10.5)
                .color(secondary(ui)),
        );
        ui.horizontal(|ui| match geo.status() {
            blip_core::geoip::GeoStatus::Downloading(p) => {
                ui.spinner();
                let txt = if p >= 0.0 {
                    tf("Downloading… %lld%%", &[&((p * 100.0) as i64)])
                } else {
                    t("Downloading…")
                };
                ui.label(RichText::new(txt).size(10.5));
            }
            blip_core::geoip::GeoStatus::Failed(e) => {
                ui.label(RichText::new(t(&e)).size(10.5).color(theme::RED));
                if ui.button(t("Try Again")).clicked() {
                    geo.download(c.app.repaint_fn());
                }
            }
            _ => {
                if ui.button(t("Download")).clicked() {
                    geo.download(c.app.repaint_fn());
                }
            }
        });
        return;
    }
    let mut points: Vec<(u32, String, f32, f32, String)> = Vec::new();
    for h in hops {
        if let Some(g) = c.geo.get(geo, &h.host) {
            let label = [g.city.clone(), g.country.clone()]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(", ");
            if points
                .last()
                .is_some_and(|p| (p.2 - g.lon as f32).abs() < 0.01 && (p.3 - g.lat as f32).abs() < 0.01)
            {
                continue;
            }
            points.push((h.hop, h.host.clone(), g.lon as f32, g.lat as f32, label));
        }
    }
    let height = if c.detached { 320.0 } else { 170.0 };
    let (rect, resp) = ui.allocate_exact_size(Vec2::new(c.width, height), Sense::click_and_drag());
    let id = ui.scope_id().with("trace-map");
    let fitted = fit(&points);
    let mut view: View = ui.ctx().data(|d| d.get_temp(id)).unwrap_or(fitted);
    if resp.double_clicked() {
        view = fitted;
    }
    let scale_of = |v: &View| rect.width() / v.span_lon;
    if resp.dragged() {
        let d = resp.drag_delta();
        let s = scale_of(&view);
        view.center.0 -= d.x / s;
        view.center.1 += d.y / s;
    }
    if resp.hovered() {
        let scroll = ui.input(|i| i.smooth_scroll_delta.y);
        if scroll != 0.0 {
            view.span_lon = (view.span_lon * (1.0 - scroll * 0.002)).clamp(2.0, 360.0);
        }
    }
    ui.ctx().data_mut(|d| d.insert_temp(id, view));
    let s = scale_of(&view);
    let project = |lon: f32, lat: f32| {
        Pos2::new(
            rect.center().x + (lon - view.center.0) * s,
            rect.center().y - (lat - view.center.1) * s,
        )
    };

    let p = ui.painter_at(rect);
    let dark = ui.visuals().dark_mode;
    p.rect_filled(
        rect,
        6.0,
        if dark {
            Color32::from_rgb(0x12, 0x1A, 0x26)
        } else {
            Color32::from_rgb(0xDD, 0xEA, 0xF5)
        },
    );
    let coast = if dark {
        Color32::from_rgb(0x55, 0x6A, 0x80)
    } else {
        Color32::from_rgb(0x8A, 0x9C, 0xAE)
    };
    for ring in rings() {
        let pts: Vec<Pos2> = ring.iter().map(|(lon, lat)| project(*lon, *lat)).collect();
        let bb = Rect::from_points(&pts);
        if !bb.intersects(rect) {
            continue;
        }
        p.add(PathShape::closed_line(pts, PathStroke::new(1.0, coast)));
    }
    let route_color = theme::category_color(crate::theme::Category::Network);
    let path: Vec<Pos2> = points.iter().map(|q| project(q.2, q.3)).collect();
    if path.len() > 1 {
        p.add(PathShape::line(path.clone(), PathStroke::new(2.0, route_color)));
    }
    let mut hovered: Option<usize> = None;
    let pointer = ui.input(|i| i.pointer.hover_pos());
    for (i, q) in path.iter().enumerate() {
        let last = i + 1 == path.len();
        p.circle_filled(
            *q,
            if last { 5.0 } else { 4.0 },
            if last { theme::RED } else { route_color },
        );
        p.circle_stroke(*q, if last { 5.0 } else { 4.0 }, Stroke::new(1.0, Color32::WHITE));
        p.text(
            *q + Vec2::new(6.0, -6.0),
            Align2::LEFT_BOTTOM,
            points[i].0.to_string(),
            FontId::proportional(9.0),
            if dark { Color32::WHITE } else { Color32::BLACK },
        );
        if pointer.is_some_and(|pt| pt.distance(*q) < 8.0) {
            hovered = Some(i);
        }
    }
    if let Some(i) = hovered {
        let q = &points[i];
        resp.on_hover_text(format!("#{} {}\n{}", q.0, q.1, q.4));
    }
    if points.is_empty() {
        p.text(
            rect.center(),
            Align2::CENTER_CENTER,
            t("No public hops to plot yet."),
            FontId::proportional(11.0),
            secondary(ui),
        );
    }
    ui.horizontal(|ui| {
        ui.label(
            RichText::new(t("IP geolocation by"))
                .size(9.5)
                .color(theme::tertiary(ui)),
        );
        if ui.link(RichText::new("DB-IP").size(9.5)).clicked() {
            blip_platform::open(blip_core::geoip::ATTRIBUTION_URL);
        }
        ui.label(
            RichText::new("· Natural Earth")
                .size(9.5)
                .color(theme::tertiary(ui)),
        );
    });
}

fn fit(points: &[(u32, String, f32, f32, String)]) -> View {
    if points.is_empty() {
        return View {
            center: (0.0, 20.0),
            span_lon: 360.0,
        };
    }
    let (mut x0, mut x1, mut y0, mut y1) = (f32::MAX, f32::MIN, f32::MAX, f32::MIN);
    for p in points {
        x0 = x0.min(p.2);
        x1 = x1.max(p.2);
        y0 = y0.min(p.3);
        y1 = y1.max(p.3);
    }
    let span = ((x1 - x0).max((y1 - y0) * 1.8) * 1.5).clamp(8.0, 360.0);
    View {
        center: ((x0 + x1) / 2.0, (y0 + y1) / 2.0),
        span_lon: span,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn world_outline_parses() {
        let r = super::rings();
        assert!(r.len() > 100);
        assert!(r.iter().all(|ring| ring
            .iter()
            .all(|(lon, lat)| lon.abs() <= 180.0 && lat.abs() <= 90.0)));
    }
}
