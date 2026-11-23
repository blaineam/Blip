//! Blip for Windows — the tray app and the `blip-cli` command line share this crate.

pub mod app;
pub mod cli;
pub mod demo;
mod panels;
mod popover;
mod publictest;
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
