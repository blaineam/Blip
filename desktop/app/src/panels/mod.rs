//! Detail panels — one per popover row, live while open. They render identically whether shown
//! beside the popover, expanded inline, or pinned into a window of their own.

mod bench;
mod disk;
mod map;
mod network;
pub mod system;

use eframe::egui::{self, Color32, RichText};

use blip_core::model::Snapshot;
use blip_core::settings::Settings;
use blip_core::{t, Icon};

use crate::sections::Section;
use crate::state::{App, Histories};
use crate::theme::{self, secondary};
use crate::widgets::IconCache;

pub const WIDTH: f32 = 300.0;

/// Side effects a panel asks the app shell to perform.
#[derive(Debug, Clone)]
pub enum Action {
    Kill(u32, String),
    OpenSettings,
    Pin(Section),
    Toast(String),
}

pub struct Ctx<'a> {
    pub app: &'a App,
    pub snap: &'a Snapshot,
    pub hist: &'a Histories,
    pub settings: &'a Settings,
    pub icons: &'a mut IconCache,
    pub geo: &'a mut GeoCache,
    pub actions: &'a mut Vec<Action>,
    pub width: f32,
    /// Shown in its own window (no pin button, roomier map).
    pub detached: bool,
}

impl Ctx<'_> {
    pub fn color(&self, s: Section) -> Color32 {
        theme::category_color(s.category())
    }
}

/// Header: icon + title (+ trailing status), pin button when floating beside the popover.
pub fn header(ui: &mut egui::Ui, c: &mut Ctx, s: Section, trailing: impl FnOnce(&mut egui::Ui)) {
    ui.horizontal(|ui| {
        theme::icon(ui, s.icon(), 15.0, c.color(s));
        ui.label(RichText::new(s.title()).font(theme::bold(14.5)));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if !c.detached
                && theme::icon_button(
                    ui,
                    Icon::Pin,
                    11.0,
                    secondary(ui),
                    &t("Pin this panel into its own window"),
                )
                .clicked()
            {
                c.actions.push(Action::Pin(s));
            }
            trailing(ui);
        });
    });
    ui.add_space(2.0);
}

pub fn section_label(ui: &mut egui::Ui, text: &str) {
    ui.add_space(4.0);
    ui.label(RichText::new(text).size(10.5).color(secondary(ui)));
}

pub fn divider(ui: &mut egui::Ui) {
    ui.add_space(3.0);
    ui.separator();
    ui.add_space(1.0);
}

pub fn show(ui: &mut egui::Ui, s: Section, c: &mut Ctx) {
    ui.set_width(c.width);
    match s {
        Section::Cpu => system::cpu(ui, c),
        Section::Memory => system::memory(ui, c),
        Section::Disk => disk::show(ui, c),
        Section::Network => network::show(ui, c),
        Section::Gpu => system::gpu(ui, c),
        Section::Thermal => system::thermal(ui, c),
        Section::Bench => bench::show(ui, c),
        Section::Battery => system::battery(ui, c),
        Section::Awake => system::awake(ui, c),
    }
}

pub use network::GeoCache;
