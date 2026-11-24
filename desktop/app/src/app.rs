//! The app shell: tray icon ↔ popover, popover placement beside the tray, hover detail panels,
//! inline mode, pinning, pinned panel windows, Settings, and close-on-click-away.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use eframe::egui::{self, Pos2, Rect, Vec2, ViewportBuilder, ViewportCommand, ViewportId};

use blip_core::settings::{DetailStyle, ThemeChoice};
use blip_core::t;

use crate::panels::{self, Action, GeoCache};
use crate::popover;
use crate::sections::Section;
use crate::settings_ui::Drafts;
use crate::state::{App, Shared};
use crate::theme;
use crate::tray::Tray;
use crate::widgets::IconCache;
use crate::winsys::{self, WorkArea};

pub enum UiEvent {
    /// Tray clicked: icon rect in physical pixels.
    TrayClick(Option<(f32, f32, f32, f32)>),
    Show,
    OpenSettings,
    Quit,
}

pub struct BlipApp {
    app: App,
    tray: Option<Tray>,
    events: Receiver<UiEvent>,
    icons: IconCache,
    geo: GeoCache,
    visible: bool,
    shown_at: Instant,
    hidden_at: Instant,
    anchor: Option<(f32, f32, f32, f32)>,
    work: Option<WorkArea>,
    pos: Pos2,
    size: Vec2,
    hover: Option<Section>,
    hover_row: Rect,
    left_at: Option<Instant>,
    panel_hovered: bool,
    panel_focused: bool,
    panel_size: Vec2,
    expanded: Option<Section>,
    settings_open: bool,
    settings_focused: bool,
    drafts: Drafts,
    pinned_panels: Vec<Section>,
    toast: Option<(String, Instant)>,
    last_tray: Instant,
    last_samples: u64,
    light_taskbar: bool,
    theme: Option<ThemeChoice>,
    quitting: bool,
    pending_show: bool,
    /// The popover has held focus since it was last shown (Windows can refuse focus to a
    /// background app, so click-away only fires after a real focus → blur).
    had_focus: bool,
}

impl BlipApp {
    pub fn new(
        cc: &eframe::CreationContext,
        app: App,
        tx: Sender<UiEvent>,
        rx: Receiver<UiEvent>,
        start_visible: bool,
    ) -> Self {
        let ctx = cc.egui_ctx.clone();
        theme::install_fonts(&ctx);
        theme::install_styles(&ctx);
        let rp_ctx = ctx.clone();
        app.set_repaint(Arc::new(move || rp_ctx.request_repaint()));
        if std::env::args().any(|a| a == "--demo") {
            // Fixed sample data for screenshots: nothing is measured.
            let mut live = app.live.write().unwrap();
            live.snapshot = crate::demo::snapshot();
            live.history = crate::demo::histories();
            live.samples = 60;
        } else {
            app.start_sampler();
        }

        // Tray events arrive on the UI thread's message loop; forward them and wake egui (the
        // window may be hidden, so nothing else would).
        {
            let tx = tx.clone();
            let ctx = ctx.clone();
            tray_icon::TrayIconEvent::set_event_handler(Some(move |e: tray_icon::TrayIconEvent| {
                if let tray_icon::TrayIconEvent::Click {
                    rect,
                    button: tray_icon::MouseButton::Left,
                    button_state: tray_icon::MouseButtonState::Up,
                    ..
                } = e
                {
                    let r = (
                        rect.position.x as f32,
                        rect.position.y as f32,
                        rect.size.width as f32,
                        rect.size.height as f32,
                    );
                    let _ = tx.send(UiEvent::TrayClick(Some(r)));
                    ctx.request_repaint();
                } else if let tray_icon::TrayIconEvent::Click {
                    rect,
                    button: tray_icon::MouseButton::Right,
                    button_state: tray_icon::MouseButtonState::Up,
                    ..
                } = e
                {
                    let r = (
                        rect.position.x as f32,
                        rect.position.y as f32,
                        rect.size.width as f32,
                        rect.size.height as f32,
                    );
                    let _ = tx.send(UiEvent::TrayClick(Some(r)));
                    ctx.request_repaint();
                }
            }));
        }
        let _ = tx;
        let now = Instant::now();
        Self {
            app,
            tray: None,
            events: rx,
            icons: IconCache::default(),
            geo: GeoCache::default(),
            visible: false,
            shown_at: now,
            hidden_at: now - Duration::from_secs(5),
            anchor: None,
            work: None,
            pos: Pos2::ZERO,
            size: Vec2::new(popover::WIDTH, 300.0),
            hover: None,
            hover_row: Rect::NOTHING,
            left_at: None,
            panel_hovered: false,
            panel_focused: false,
            panel_size: Vec2::new(panels::WIDTH + 24.0, 400.0),
            expanded: None,
            settings_open: false,
            settings_focused: false,
            drafts: Drafts::default(),
            pinned_panels: Vec::new(),
            toast: None,
            last_tray: now - Duration::from_secs(10),
            last_samples: 0,
            light_taskbar: winsys::light_taskbar(),
            theme: None,
            quitting: false,
            pending_show: start_visible,
            had_focus: false,
        }
    }

    fn show_popover(&mut self, ctx: &egui::Context) {
        if self.anchor.is_none() {
            self.anchor = self.tray.as_ref().and_then(|t| t.anchor()).map(|r| {
                (
                    r.position.x as f32,
                    r.position.y as f32,
                    r.size.width as f32,
                    r.size.height as f32,
                )
            });
        }
        self.work = self
            .anchor
            .and_then(|a| winsys::work_area_at(a.0 + a.2 / 2.0, a.1 + a.3 / 2.0));
        self.visible = true;
        self.had_focus = false;
        self.shown_at = Instant::now();
        self.hover = None;
        self.place(ctx);
        ctx.send_viewport_cmd(ViewportCommand::Visible(true));
        ctx.send_viewport_cmd(ViewportCommand::Focus);
        ctx.request_repaint();
    }

    fn hide_popover(&mut self, ctx: &egui::Context) {
        self.visible = false;
        self.hidden_at = Instant::now();
        self.hover = None;
        ctx.send_viewport_cmd(ViewportCommand::Visible(false));
    }

    /// Work area in points (logical).
    fn work_points(&self, ctx: &egui::Context) -> Rect {
        if let Some(w) = self.work {
            return Rect::from_min_max(
                Pos2::new(w.left / w.scale, w.top / w.scale),
                Pos2::new(w.right / w.scale, w.bottom / w.scale),
            );
        }
        let size = ctx
            .input(|i| i.viewport().monitor_size)
            .unwrap_or(Vec2::new(1440.0, 900.0));
        Rect::from_min_max(Pos2::new(0.0, 28.0), Pos2::new(size.x, size.y))
    }

    /// Places the popover next to the tray icon, on whichever edge the taskbar is.
    fn place(&mut self, ctx: &egui::Context) {
        if self.app.settings().popover_pinned && self.pos != Pos2::ZERO {
            return;
        }
        let work = self.work_points(ctx);
        let size = self.size;
        let margin = 8.0;
        let pos = match (self.anchor, self.work) {
            (Some(a), Some(w)) => {
                let s = w.scale;
                let ar = Rect::from_min_size(Pos2::new(a.0 / s, a.1 / s), Vec2::new(a.2 / s, a.3 / s));
                let x_centered = (ar.center().x - size.x / 2.0)
                    .clamp(work.left() + margin, work.right() - size.x - margin);
                if ar.top() >= work.bottom() - 1.0 {
                    Pos2::new(x_centered, work.bottom() - size.y - margin)
                } else if ar.bottom() <= work.top() + 1.0 {
                    Pos2::new(x_centered, work.top() + margin)
                } else if ar.left() >= work.right() - 1.0 {
                    Pos2::new(
                        work.right() - size.x - margin,
                        (ar.center().y - size.y / 2.0)
                            .clamp(work.top() + margin, work.bottom() - size.y - margin),
                    )
                } else if ar.right() <= work.left() + 1.0 {
                    Pos2::new(
                        work.left() + margin,
                        (ar.center().y - size.y / 2.0)
                            .clamp(work.top() + margin, work.bottom() - size.y - margin),
                    )
                } else {
                    // Overflow flyout (^): the icon sits above the taskbar.
                    Pos2::new(x_centered, (ar.top() - size.y - margin).max(work.top() + margin))
                }
            }
            _ => Pos2::new(work.right() - size.x - margin, work.top() + margin),
        };
        if (pos - self.pos).length() > 0.5 {
            self.pos = pos;
            ctx.send_viewport_cmd(ViewportCommand::OuterPosition(pos));
        }
    }

    fn handle_actions(&mut self, actions: Vec<Action>) {
        for a in actions {
            match a {
                Action::Kill(pid, name) => {
                    if let Err(e) = blip_platform::kill_process(pid) {
                        self.toast = Some((
                            format!("{} — {e}", blip_core::recommend::display_name(&name)),
                            Instant::now(),
                        ));
                    }
                }
                Action::OpenSettings => self.settings_open = true,
                Action::Pin(s) => {
                    if !self.pinned_panels.contains(&s) {
                        self.pinned_panels.push(s);
                    }
                    self.hover = None;
                }
                Action::Toast(m) => self.toast = Some((m, Instant::now())),
            }
        }
    }

    fn panel_ctx_run(&mut self, ui: &mut egui::Ui, sec: Section, width: f32, detached: bool) -> Vec<Action> {
        let snap = self.app.snapshot();
        let hist = self.app.live.read().unwrap().history.clone();
        let settings = self.app.settings();
        let mut actions = Vec::new();
        let mut c = panels::Ctx {
            app: &self.app,
            snap: &snap,
            hist: &hist,
            settings: &settings,
            icons: &mut self.icons,
            geo: &mut self.geo,
            actions: &mut actions,
            width,
            detached,
        };
        panels::show(ui, sec, &mut c);
        actions
    }

    fn detail_panel(&mut self, ctx: &egui::Context, sec: Section) {
        let work = self.work_points(ctx);
        let w = self.panel_size.x;
        let left_side = self.pos.x + self.size.x / 2.0 > work.center().x;
        let x = if left_side {
            self.pos.x - w - 6.0
        } else {
            self.pos.x + self.size.x + 6.0
        };
        let max_h = (work.height() - 16.0).max(200.0);
        let h = self.panel_size.y.min(max_h);
        let y = (self.pos.y + self.hover_row.top() - 8.0)
            .clamp(work.top() + 8.0, (work.bottom() - h - 8.0).max(work.top() + 8.0));
        let builder = ViewportBuilder::default()
            .with_title(format!("Blip — {}", sec.title()))
            .with_decorations(false)
            .with_transparent(true)
            .with_resizable(false)
            .with_taskbar(false)
            .with_always_on_top()
            .with_active(false)
            .with_position(Pos2::new(x, y))
            .with_inner_size(Vec2::new(w, h));
        let mut actions = Vec::new();
        let mut measured = self.panel_size;
        let mut hovered = false;
        let mut focused = false;
        ctx.show_viewport_immediate(ViewportId::from_hash_of("blip-detail"), builder, |ui, _| {
            hovered = ui.ctx().input(|i| i.pointer.has_pointer());
            focused = ui.ctx().input(|i| i.viewport().focused.unwrap_or(false));
            ui.ctx()
                .send_viewport_cmd(ViewportCommand::OuterPosition(Pos2::new(x, y)));
            let frame = card_frame(ui);
            let r = frame.show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .max_height(max_h - 24.0)
                    .auto_shrink([false, true])
                    .show(ui, |ui| {
                        actions = self.panel_ctx_run(ui, sec, panels::WIDTH, false);
                    });
            });
            let hgt = r.response.rect.height();
            measured = Vec2::new(w, hgt.min(max_h));
            if (hgt.min(max_h) - h).abs() > 1.0 {
                ui.ctx().send_viewport_cmd(ViewportCommand::InnerSize(measured));
            }
        });
        self.panel_size = measured;
        self.panel_hovered = hovered;
        self.panel_focused = focused;
        self.handle_actions(actions);
    }
}

fn card_frame(ui: &egui::Ui) -> egui::Frame {
    let v = ui.visuals();
    egui::Frame::new()
        .fill(v.panel_fill)
        .corner_radius(10.0)
        .stroke(egui::Stroke::new(
            1.0,
            if v.dark_mode {
                egui::Color32::from_white_alpha(28)
            } else {
                egui::Color32::from_black_alpha(30)
            },
        ))
        .inner_margin(egui::Margin::same(12))
}

impl eframe::App for BlipApp {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        [0.0, 0.0, 0.0, 0.0]
    }

    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if self.tray.is_none() {
            self.tray = Some(Tray::new());
        }
        let settings = self.app.settings();
        if self.theme != Some(settings.theme) {
            ctx.set_theme(match settings.theme {
                ThemeChoice::System => egui::ThemePreference::System,
                ThemeChoice::Light => egui::ThemePreference::Light,
                ThemeChoice::Dark => egui::ThemePreference::Dark,
            });
            self.theme = Some(settings.theme);
        }
        while let Ok(ev) = self.events.try_recv() {
            match ev {
                UiEvent::TrayClick(rect) => {
                    if rect.is_some() {
                        self.anchor = rect;
                    }
                    // A click that also stole focus (and so just hid us) is a toggle-off.
                    if self.visible {
                        self.hide_popover(ctx);
                    } else if self.hidden_at.elapsed() > Duration::from_millis(250) {
                        self.show_popover(ctx);
                    }
                }
                UiEvent::Show => self.show_popover(ctx),
                UiEvent::OpenSettings => self.settings_open = true,
                UiEvent::Quit => {
                    self.quitting = true;
                    ctx.send_viewport_cmd(ViewportCommand::Close);
                }
            }
        }
        if self.pending_show {
            self.pending_show = false;
            self.show_popover(ctx);
        }
        let running = crate::publictest::pump();
        let samples = self.app.live.read().unwrap().samples;
        if samples != self.last_samples || self.last_tray.elapsed() > Duration::from_secs(5) {
            self.last_samples = samples;
            self.last_tray = Instant::now();
            if samples.is_multiple_of(15) {
                self.light_taskbar = winsys::light_taskbar();
            }
            let snap = self.app.snapshot();
            if let Some(t) = self.tray.as_mut() {
                t.update(&snap, &settings, self.light_taskbar);
            }
        }
        if running
            || self.app.bench.is_running()
            || self.app.speed.is_running()
            || self.app.disk.state().running
        {
            ctx.request_repaint_after(Duration::from_millis(250));
        }
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        if ctx.input(|i| i.viewport().close_requested()) && !self.quitting {
            ctx.send_viewport_cmd(ViewportCommand::CancelClose);
            self.hide_popover(&ctx);
        }
        let settings = self.app.settings();
        let snap = self.app.snapshot();

        if self.visible {
            let inline = settings.detail_panel_style == DetailStyle::Inline;
            let width = if inline && self.expanded.is_some() {
                panels::WIDTH + 24.0
            } else {
                popover::WIDTH
            };
            let frame = card_frame(ui).inner_margin(egui::Margin::symmetric(0, 6));
            let mut out = popover::Outcome::default();
            let max_h = self.work_points(&ctx).height() - 16.0;
            let r = frame.show(ui, |ui| {
                ui.set_width(width);
                egui::ScrollArea::vertical()
                    .max_height(max_h)
                    .auto_shrink([false, true])
                    .show(ui, |ui| {
                        let app = self.app.clone();
                        let active = if inline { self.expanded } else { self.hover };
                        out = popover::show(ui, &app, &snap, &settings, active, &mut |ui, sec| {
                            let a = self.panel_ctx_run(ui, sec, width - 20.0, false);
                            self.handle_actions(a);
                        });
                    });
                if let Some((msg, at)) = &self.toast {
                    if at.elapsed() < Duration::from_secs(4) {
                        ui.add_space(2.0);
                        ui.label(egui::RichText::new(msg).size(10.5).color(theme::ORANGE));
                        ctx.request_repaint_after(Duration::from_millis(500));
                    }
                }
            });
            let new_size = Vec2::new(width, r.response.rect.height());
            if (new_size - self.size).length() > 0.5 {
                self.size = new_size;
                ctx.send_viewport_cmd(ViewportCommand::InnerSize(new_size));
                self.place(&ctx);
            }

            // Hover → beside panel (with a grace period for the trip across the gap).
            if !inline {
                if let Some((sec, rect)) = out.hovered {
                    self.hover = Some(sec);
                    self.hover_row = rect;
                    self.left_at = None;
                } else if self.hover.is_some() && !self.panel_hovered {
                    let since = *self.left_at.get_or_insert_with(Instant::now);
                    if since.elapsed() > Duration::from_millis(350) && !ctx.input(|i| i.pointer.has_pointer())
                    {
                        self.hover = None;
                        self.left_at = None;
                    } else {
                        ctx.request_repaint_after(Duration::from_millis(100));
                    }
                } else if self.panel_hovered {
                    self.left_at = None;
                }
                if let Some(sec) = out.clicked {
                    self.hover = Some(sec);
                }
                if let Some(sec) = self.hover {
                    self.detail_panel(&ctx, sec);
                }
            } else if let Some(sec) = out.clicked {
                self.expanded = if self.expanded == Some(sec) {
                    None
                } else {
                    Some(sec)
                };
            }

            if out.open_settings || out.support {
                self.settings_open = true;
            }
            if out.toggle_pin {
                self.app.update_settings(|s| s.popover_pinned = !s.popover_pinned);
                if !self.app.settings().popover_pinned {
                    self.place(&ctx);
                }
            }
            if out.drag && settings.popover_pinned {
                ctx.send_viewport_cmd(ViewportCommand::StartDrag);
            }
            if let Some(id) = out.dismiss {
                self.app.update_settings(|s| s.dismissed_recommendations.push(id));
            }
            if out.share {
                let speeds = self.app.speed.state().history;
                let bench = self.app.bench.state().last_result;
                let md = blip_core::export::markdown(&snap, &speeds, bench.as_ref());
                if let Some(p) = crate::shell::save_snapshot(&md) {
                    self.toast = Some((blip_core::tf("Saved %@", &[&p]), Instant::now()));
                }
            }
            if out.quit {
                self.quitting = true;
                self.app.stop_awake();
                ctx.send_viewport_cmd(ViewportCommand::Close);
            }

            // Click-away closes (unless pinned, or focus moved to one of our own windows).
            let focused = ctx.input(|i| i.viewport().focused.unwrap_or(true));
            if focused {
                self.had_focus = true;
            }
            if !settings.popover_pinned
                && self.had_focus
                && !focused
                && !self.panel_focused
                && !self.settings_focused
                && self.shown_at.elapsed() > Duration::from_millis(300)
            {
                self.hide_popover(&ctx);
            }
        }

        // Pinned panel windows.
        let mut close: Vec<Section> = Vec::new();
        for sec in self.pinned_panels.clone() {
            let builder = ViewportBuilder::default()
                .with_title(format!("Blip — {}", sec.title()))
                .with_inner_size(Vec2::new(panels::WIDTH + 32.0, 560.0))
                .with_min_inner_size(Vec2::new(panels::WIDTH + 32.0, 200.0))
                .with_always_on_top();
            ctx.show_viewport_immediate(
                ViewportId::from_hash_of(("blip-pinned", sec.key())),
                builder,
                |ui, _| {
                    if ui.ctx().input(|i| i.viewport().close_requested()) {
                        close.push(sec);
                    }
                    egui::Frame::central_panel(ui.style()).show(ui, |ui| {
                        egui::ScrollArea::vertical()
                            .auto_shrink([false, false])
                            .show(ui, |ui| {
                                let a = self.panel_ctx_run(ui, sec, panels::WIDTH, true);
                                self.handle_actions(a);
                            });
                    });
                },
            );
        }
        self.pinned_panels.retain(|s| !close.contains(s));

        // Settings window.
        self.settings_focused = false;
        if self.settings_open {
            let builder = ViewportBuilder::default()
                .with_title(t("Blip Settings"))
                .with_inner_size(Vec2::new(520.0, 680.0))
                .with_min_inner_size(Vec2::new(420.0, 400.0));
            let mut open = true;
            let mut focused = false;
            ctx.show_viewport_immediate(ViewportId::from_hash_of("blip-settings"), builder, |ui, _| {
                if ui.ctx().input(|i| i.viewport().close_requested()) {
                    open = false;
                }
                focused = ui.ctx().input(|i| i.viewport().focused.unwrap_or(false));
                egui::Frame::central_panel(ui.style()).show(ui, |ui| {
                    crate::settings_ui::show(ui, &self.app, &mut self.drafts);
                });
            });
            self.settings_open = open;
            self.settings_focused = focused;
        }
    }

    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        self.app.stop_awake();
        self.app.trace.stop();
        self.app.bench.cancel();
        self.app.speed.cancel();
    }
}

pub fn run(start_visible: bool) -> eframe::Result<()> {
    let app = Shared::new();
    let (tx, rx) = channel();
    {
        let tx = tx.clone();
        if !winsys::claim_single_instance(move || {
            let _ = tx.send(UiEvent::Show);
        }) {
            return Ok(());
        }
    }
    let first_run = !app.settings().first_run_done;
    if first_run {
        app.update_settings(|s| s.first_run_done = true);
    }
    let options = eframe::NativeOptions {
        viewport: ViewportBuilder::default()
            .with_title("Blip")
            .with_app_id("com.blainemiller.Blip")
            .with_decorations(false)
            .with_transparent(true)
            .with_resizable(false)
            .with_taskbar(false)
            .with_always_on_top()
            .with_visible(false)
            .with_inner_size(Vec2::new(popover::WIDTH, 300.0)),
        persist_window: false,
        ..Default::default()
    };
    let show_now = start_visible || first_run;
    eframe::run_native(
        "Blip",
        options,
        Box::new(move |cc| Ok(Box::new(BlipApp::new(cc, app, tx, rx, show_now)))),
    )
}
