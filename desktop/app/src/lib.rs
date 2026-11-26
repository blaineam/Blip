//! Blip for Windows and Linux — the tray app and the `blip-cli` command line share this crate.

/// The release version: CI sets `BLIP_VERSION` from the tag (e.g. "2.1.0-preview.2"), so the
/// installer can tell previews apart; local builds use the crate version.
pub const VERSION: &str = match option_env!("BLIP_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

/// Set from any thread (Settings' "Install Blip…", another copy's quit request); the UI
/// thread notices on its next frame and quits cleanly (Keep Awake released, lid restored).
pub static QUIT_REQUESTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub mod app;
pub mod cli;
pub mod demo;
mod fit;
#[cfg(windows)]
pub mod install;
mod panels;
mod popover;
mod publictest;
mod report;
#[cfg(test)]
mod screens;
mod sections;
mod settings_ui;
mod shell;
mod state;
mod theme;
mod timefmt;
mod tray;
mod widgets;
mod winsys;
