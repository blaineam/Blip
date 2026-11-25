//! Blip's platform-neutral core for Windows and Linux.

pub mod bench;
pub mod disktest;
pub mod export;
pub mod fmt;
pub mod geoip;
pub mod grades;
pub mod history;
pub mod i18n;
pub mod log;
pub mod metrics;
pub mod model;
pub mod paths;
pub mod recommend;
pub mod settings;
pub mod speedtest;
mod strings;
pub mod trace;

pub use i18n::{t, tf};
pub use log::log;

/// Semantic icons; the UI maps them to the platform's symbol font (Segoe Fluent Icons on
/// Windows), the way the Mac maps them to SF Symbols.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Icon {
    Cpu,
    Memory,
    Disk,
    Network,
    Wifi,
    Ethernet,
    Gpu,
    Thermometer,
    Battery,
    BatteryCharging,
    Bench,
    Awake,
    Warning,
    Info,
    Settings,
    Power,
    Pin,
    Pinned,
    Share,
    Clock,
    Computer,
    Windows,
    /// A terminal prompt: the OS footer on Linux.
    Linux,
    Speed,
    Route,
    Map,
    Copy,
    Close,
    Play,
    Stop,
    Refresh,
    ChevronRight,
    ChevronDown,
    Fan,
    Lifebuoy,
    Folder,
    Globe,
    Shield,
    Kill,
    Up,
    Down,
    Check,
}

/// The public address, via api.ipify.org (the same service the Mac uses), fetched only when the
/// user taps "reveal".
pub fn wan_ip() -> Option<String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(std::time::Duration::from_secs(8)))
        .build()
        .into();
    let mut resp = agent.get("https://api.ipify.org").call().ok()?;
    let ip = resp.body_mut().read_to_string().ok()?.trim().to_string();
    trace::is_valid_host(&ip).then_some(ip)
}
