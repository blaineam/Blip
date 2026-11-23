//! User settings, persisted as JSON. Field names follow the Mac app's `@AppStorage` keys so the
//! `blip get/set` CLI speaks the same vocabulary as the Mac's Get/Set Setting shortcuts.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum TrayStyle {
    /// One icon with a mini bar per enabled metric (the Mac's menu-bar look, in 16 px).
    #[default]
    Bars,
    /// One icon per enabled metric, each showing its number.
    Numbers,
    /// The Blip logo only; values live in the tooltip and popover.
    Logo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum DetailStyle {
    /// Hover a row → a live panel opens beside the popover.
    #[default]
    Beside,
    /// Click a row → its details expand inside the popover.
    Inline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SpeedServerKind {
    #[default]
    Public,
    SelfHosted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ThemeChoice {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    // Tray ("menu bar")
    #[serde(rename = "showCPU")]
    pub show_cpu: bool,
    pub show_memory: bool,
    pub show_disk: bool,
    #[serde(rename = "showGPU")]
    pub show_gpu: bool,
    pub show_network_dot: bool,
    pub tray_style: TrayStyle,
    pub show_measurement_labels: bool,
    pub show_value_labels: bool,
    /// "" = category colours, "monochrome", or "#RRGGBB".
    pub accent_color_override: String,
    pub colorize_utilization: bool,
    // Popover
    pub show_recommendations: bool,
    pub dismissed_recommendations: Vec<String>,
    pub popover_pinned: bool,
    pub detail_panel_style: DetailStyle,
    pub theme: ThemeChoice,
    /// "" = follow Windows.
    pub language: String,
    pub update_interval_secs: u64,
    // Network
    pub ping_target: String,
    pub traceroute_target: String,
    pub trace_map_shown: bool,
    pub speed_test_server_kind: SpeedServerKind,
    #[serde(rename = "speedTestOpenSpeedTestURL")]
    pub speed_test_open_speed_test_url: String,
    pub net_speed_auto_run: bool,
    pub net_speed_interval: u32,
    pub net_speed_expanded: bool,
    pub trace_expanded: bool,
    // Disk
    pub disk_speed_auto_run: bool,
    pub disk_speed_interval: u32,
    /// MB: 128 / 512 / 1024.
    pub disk_speed_size: u32,
    /// "" = the system drive; else a folder path.
    pub disk_speed_target: String,
    pub disk_speed_expanded: bool,
    // GeoIP
    #[serde(rename = "geoipAutoUpdate")]
    pub geoip_auto_update: bool,
    // Keep Awake
    pub keep_awake_display: bool,
    /// Minutes; 0 = until turned off.
    pub keep_awake_minutes: u32,
    pub keep_awake_lid_closed: bool,
    pub keep_awake_jiggle: bool,
    // System
    pub launch_at_login: bool,
    pub first_run_done: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            show_cpu: true,
            show_memory: true,
            show_disk: true,
            show_gpu: false,
            show_network_dot: true,
            tray_style: TrayStyle::Bars,
            show_measurement_labels: true,
            show_value_labels: true,
            accent_color_override: String::new(),
            colorize_utilization: false,
            show_recommendations: true,
            dismissed_recommendations: Vec::new(),
            popover_pinned: false,
            detail_panel_style: DetailStyle::Beside,
            theme: ThemeChoice::System,
            language: String::new(),
            update_interval_secs: 2,
            ping_target: "1.1.1.1".into(),
            traceroute_target: "1.1.1.1".into(),
            trace_map_shown: false,
            speed_test_server_kind: SpeedServerKind::Public,
            speed_test_open_speed_test_url: String::new(),
            net_speed_auto_run: false,
            net_speed_interval: 60,
            net_speed_expanded: true,
            trace_expanded: false,
            disk_speed_auto_run: false,
            disk_speed_interval: 60,
            disk_speed_size: 512,
            disk_speed_target: String::new(),
            disk_speed_expanded: true,
            geoip_auto_update: true,
            keep_awake_display: true,
            keep_awake_minutes: 0,
            keep_awake_lid_closed: false,
            keep_awake_jiggle: false,
            launch_at_login: false,
            first_run_done: false,
        }
    }
}

impl Settings {
    pub fn load() -> Self {
        crate::paths::load_json(&crate::paths::settings_file()).unwrap_or_default()
    }

    pub fn save(&self) {
        crate::paths::save_json(&crate::paths::settings_file(), self);
    }

    /// Curated keys the CLI may read and write, with validation — the desktop twin of the Mac's
    /// `BlipSettingDescriptor` catalog.
    pub const CLI_KEYS: &'static [(&'static str, &'static str)] = &[
        ("showCPU", "bool — CPU in the tray"),
        ("showMemory", "bool — memory in the tray"),
        ("showDisk", "bool — disk in the tray"),
        ("showGPU", "bool — GPU in the tray"),
        ("showNetworkDot", "bool — connectivity dot in the tray"),
        ("trayStyle", "bars | numbers | logo"),
        ("colorizeUtilization", "bool — colour bars by load"),
        ("showRecommendations", "bool — suggestion banner"),
        ("detailPanelStyle", "beside | inline"),
        ("pingTarget", "host — WAN ping target"),
        ("tracerouteTarget", "host — traceroute target"),
        ("speedTestServerKind", "public | selfhosted"),
        (
            "speedTestOpenSpeedTestURL",
            "URL of a self-hosted OpenSpeedTest server",
        ),
        (
            "netSpeedAutoRun",
            "bool — interval network speed tests (self-hosted only)",
        ),
        ("netSpeedInterval", "minutes (5–1440)"),
        ("diskSpeedAutoRun", "bool — interval disk speed tests"),
        ("diskSpeedInterval", "minutes (5–1440)"),
        ("diskSpeedSize", "128 | 512 | 1024 (MB)"),
        ("launchAtLogin", "bool"),
        ("updateIntervalSecs", "seconds (1–10)"),
    ];

    pub fn get(&self, key: &str) -> Option<String> {
        let v = serde_json::to_value(self).ok()?;
        let field = v.get(key)?;
        Some(match field {
            serde_json::Value::String(s) => s.clone(),
            other => other.to_string(),
        })
    }

    /// Validates and applies one CLI write. Returns a human-readable error on bad input.
    pub fn set(&mut self, key: &str, value: &str) -> Result<(), String> {
        if !Self::CLI_KEYS.iter().any(|(k, _)| *k == key) {
            return Err(format!("unknown or read-only setting: {key}"));
        }
        let bad = || format!("That value isn't valid: {value}.");
        let parsed: serde_json::Value = match key {
            "pingTarget" | "tracerouteTarget" => {
                if !crate::trace::is_valid_host(value) {
                    return Err(format!("“{value}” isn't a valid hostname or IP address."));
                }
                value.into()
            }
            "speedTestOpenSpeedTestURL" => value.into(),
            "trayStyle" | "detailPanelStyle" | "speedTestServerKind" => value.to_ascii_lowercase().into(),
            "netSpeedInterval" | "diskSpeedInterval" => {
                let n: u32 = value.parse().map_err(|_| bad())?;
                if !(5..=1440).contains(&n) {
                    return Err(bad());
                }
                n.into()
            }
            "diskSpeedSize" => {
                let n: u32 = value.parse().map_err(|_| bad())?;
                if ![128, 512, 1024].contains(&n) {
                    return Err(bad());
                }
                n.into()
            }
            "updateIntervalSecs" => {
                let n: u64 = value.parse().map_err(|_| bad())?;
                if !(1..=10).contains(&n) {
                    return Err(bad());
                }
                n.into()
            }
            _ => match value.to_ascii_lowercase().as_str() {
                "true" | "on" | "yes" | "1" => true.into(),
                "false" | "off" | "no" | "0" => false.into(),
                _ => return Err(bad()),
            },
        };
        let mut v = serde_json::to_value(&*self).map_err(|e| e.to_string())?;
        v[key] = parsed;
        *self = serde_json::from_value(v).map_err(|_| bad())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_the_mac_keys() {
        let v = serde_json::to_value(Settings::default()).unwrap();
        for key in [
            "showCPU",
            "showGPU",
            "pingTarget",
            "speedTestOpenSpeedTestURL",
            "geoipAutoUpdate",
        ] {
            assert!(v.get(key).is_some(), "{key}");
        }
        for (key, _) in Settings::CLI_KEYS {
            assert!(v.get(*key).is_some(), "CLI key {key} isn't a field");
        }
    }

    #[test]
    fn set_validates() {
        let mut s = Settings::default();
        s.set("showGPU", "on").unwrap();
        assert!(s.show_gpu);
        s.set("trayStyle", "Numbers").unwrap();
        assert_eq!(s.tray_style, TrayStyle::Numbers);
        assert!(s.set("trayStyle", "sparkles").is_err());
        assert!(s.set("pingTarget", "-rf").is_err());
        assert!(s.set("diskSpeedSize", "300").is_err());
        assert!(s.set("firstRunDone", "true").is_err());
        assert_eq!(s.get("pingTarget").as_deref(), Some("1.1.1.1"));
    }

    #[test]
    fn missing_fields_take_defaults() {
        let s: Settings = serde_json::from_str(r#"{"showCPU":false}"#).unwrap();
        assert!(!s.show_cpu);
        assert!(s.show_memory);
    }
}
