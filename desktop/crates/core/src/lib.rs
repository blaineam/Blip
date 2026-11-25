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

/// Every HTTP client starts here, so each platform's TLS is chosen in one place. ureq defaults
/// to rustls even when only native-tls is compiled in, and then **panics** on the first https
/// request; on Windows the OS stack (SChannel, with the system's root certificates) has to be
/// selected explicitly.
pub(crate) fn http_agent() -> ureq::config::ConfigBuilder<ureq::typestate::AgentScope> {
    let builder = ureq::Agent::config_builder();
    #[cfg(windows)]
    let builder = builder.tls_config(
        ureq::tls::TlsConfig::builder()
            .provider(ureq::tls::TlsProvider::NativeTls)
            .root_certs(ureq::tls::RootCerts::PlatformVerifier)
            .build(),
    );
    builder
}

/// The public address, via api.ipify.org (the same service the Mac uses), fetched only when the
/// user taps "reveal".
pub fn wan_ip() -> Option<String> {
    let agent: ureq::Agent = http_agent()
        .timeout_global(Some(std::time::Duration::from_secs(8)))
        .build()
        .into();
    let mut resp = agent.get("https://api.ipify.org").call().ok()?;
    let ip = resp.body_mut().read_to_string().ok()?.trim().to_string();
    trace::is_valid_host(&ip).then_some(ip)
}

#[cfg(test)]
mod http_tests {
    /// A real TLS handshake with this platform's configured stack. A wrong or missing TLS
    /// provider panics here (as `windows-v2.1.0-preview.2` did on its first https request).
    #[test]
    fn https_works_on_this_platform() {
        let agent: ureq::Agent = super::http_agent()
            .timeout_global(Some(std::time::Duration::from_secs(30)))
            .user_agent("Blip (desktop)")
            .build()
            .into();
        for url in ["https://api.ipify.org", "https://download.db-ip.com/"] {
            match agent.head(url).call() {
                // Any HTTP answer means the handshake and certificate checks passed.
                Ok(_) | Err(ureq::Error::StatusCode(_)) => {}
                Err(e) => panic!("{url}: {e}"),
            }
        }
    }
}
