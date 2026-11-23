//! Local date/time strings for the UI.

use chrono::{Local, TimeZone};

pub fn time(t: std::time::SystemTime) -> String {
    let dt: chrono::DateTime<Local> = t.into();
    dt.format("%H:%M").to_string()
}

pub fn date_time(unix: u64) -> String {
    Local
        .timestamp_opt(unix as i64, 0)
        .single()
        .map(|d| d.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_default()
}

pub fn short_date(unix: u64) -> String {
    Local
        .timestamp_opt(unix as i64, 0)
        .single()
        .map(|d| d.format("%b %-d").to_string())
        .unwrap_or_default()
}

/// "5 min ago", "2 h ago", or a date.
pub fn ago(unix: u64) -> String {
    let now = blip_core::model::now_unix();
    let d = now.saturating_sub(unix);
    if d < 90 {
        blip_core::t("just now")
    } else if d < 3600 {
        blip_core::tf("%lld min ago", &[&(d / 60)])
    } else if d < 86_400 {
        blip_core::tf("%lld h ago", &[&(d / 3600)])
    } else {
        short_date(unix)
    }
}
