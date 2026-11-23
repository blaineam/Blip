//! Number formatting, matching the Mac app's `Fmt` so both platforms read the same.

/// Memory sizes (binary units, like Activity Monitor / Task Manager): "15.8 GB", "512 MB".
pub fn bytes(b: u64) -> String {
    let gb = b as f64 / 1_073_741_824.0;
    if gb >= 1.0 {
        format!("{gb:.1} GB")
    } else {
        format!("{:.0} MB", b as f64 / 1_048_576.0)
    }
}

/// Disk capacities (decimal units, like the drive's label): "512 GB", "2.0 TB".
pub fn disk_bytes(b: u64) -> String {
    let gb = b as f64 / 1e9;
    if gb >= 1000.0 {
        format!("{:.1} TB", gb / 1000.0)
    } else if gb >= 100.0 {
        format!("{gb:.0} GB")
    } else {
        format!("{gb:.1} GB")
    }
}

pub fn speed(bps: u64) -> String {
    if bps > 1_000_000 {
        format!("{:.1} MB/s", bps as f64 / 1e6)
    } else if bps > 1_000 {
        format!("{:.0} KB/s", bps as f64 / 1e3)
    } else {
        format!("{bps} B/s")
    }
}

/// Compact rate for overview rows and the tray: "4.2M", "680K".
pub fn short_speed(bps: u64) -> String {
    if bps > 1_000_000 {
        format!("{:.1}M", bps as f64 / 1e6)
    } else if bps > 1_000 {
        format!("{:.0}K", bps as f64 / 1e3)
    } else {
        "0K".into()
    }
}

pub fn chart_speed(bps: f64) -> String {
    if bps >= 1e9 {
        format!("{:.1} GB/s", bps / 1e9)
    } else if bps >= 1e6 {
        format!("{:.1} MB/s", bps / 1e6)
    } else if bps >= 1e3 {
        format!("{:.0} KB/s", bps / 1e3)
    } else {
        format!("{bps:.0} B/s")
    }
}

pub fn percent(v: f64) -> String {
    format!("{v:.0}%")
}

pub fn temperature(c: f64) -> String {
    format!("{c:.1}°C")
}

pub fn throughput(mbps: f64) -> String {
    if mbps >= 1000.0 {
        format!("{:.2} Gbps", mbps / 1000.0)
    } else {
        format!("{mbps:.0} Mbps")
    }
}

pub fn total_bytes(b: u64) -> String {
    let f = b as f64;
    if f >= 1e12 {
        format!("{:.1} TB", f / 1e12)
    } else if f >= 1e9 {
        format!("{:.1} GB", f / 1e9)
    } else if f >= 1e6 {
        format!("{:.1} MB", f / 1e6)
    } else if f >= 1e3 {
        format!("{:.0} KB", f / 1e3)
    } else {
        format!("{b} B")
    }
}

pub fn uptime(secs: u64) -> String {
    let days = secs / 86_400;
    let hours = secs % 86_400 / 3600;
    let mins = secs % 3600 / 60;
    if days > 0 {
        format!("{days}d {hours}h")
    } else if hours > 0 {
        format!("{hours}h {mins}m")
    } else {
        format!("{mins}m")
    }
}

pub fn minutes(m: u32) -> String {
    let (h, m) = (m / 60, m % 60);
    if h > 0 {
        format!("{h}h {m}m")
    } else {
        format!("{m}m")
    }
}

pub fn ms(v: Option<f64>) -> String {
    match v {
        Some(v) if v < 10.0 => format!("{v:.1} ms"),
        Some(v) => format!("{v:.0} ms"),
        None => "—".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_like_the_mac() {
        assert_eq!(short_speed(4_200_000), "4.2M");
        assert_eq!(short_speed(680_000), "680K");
        assert_eq!(short_speed(12), "0K");
        assert_eq!(throughput(930.0), "930 Mbps");
        assert_eq!(throughput(2350.0), "2.35 Gbps");
        assert_eq!(uptime(3 * 86_400 + 5 * 3600), "3d 5h");
        assert_eq!(uptime(65 * 60), "1h 5m");
        assert_eq!(total_bytes(412_000_000_000), "412.0 GB");
        assert_eq!(bytes(17_179_869_184), "16.0 GB");
        assert_eq!(disk_bytes(2_000_000_000_000), "2.0 TB");
        assert_eq!(ms(Some(2.34)), "2.3 ms");
    }
}
