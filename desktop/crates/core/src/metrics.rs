//! The metric catalog behind `blip metric <id>` — same ids as the Mac's Get System Metric
//! shortcut, so scripts port between platforms.

use crate::model::Snapshot;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unit {
    Percent,
    Bytes,
    BytesPerSecond,
    Milliseconds,
    Celsius,
    Count,
    Rpm,
    Seconds,
    Minutes,
    Level,
}

pub struct Metric {
    pub id: &'static str,
    pub title: &'static str,
    pub unit: Unit,
    /// Charted in the UI, so `--avg/--min/--max` over the last two minutes work.
    pub has_history: bool,
}

pub const CATALOG: &[Metric] = &[
    Metric {
        id: "cpu.usage",
        title: "CPU Usage",
        unit: Unit::Percent,
        has_history: true,
    },
    Metric {
        id: "cpu.user",
        title: "CPU Usage (User)",
        unit: Unit::Percent,
        has_history: false,
    },
    Metric {
        id: "cpu.system",
        title: "CPU Usage (System)",
        unit: Unit::Percent,
        has_history: false,
    },
    Metric {
        id: "cpu.load1",
        title: "Load Average (1 min)",
        unit: Unit::Count,
        has_history: false,
    },
    Metric {
        id: "cpu.load5",
        title: "Load Average (5 min)",
        unit: Unit::Count,
        has_history: false,
    },
    Metric {
        id: "cpu.load15",
        title: "Load Average (15 min)",
        unit: Unit::Count,
        has_history: false,
    },
    Metric {
        id: "memory.usage",
        title: "Memory Usage",
        unit: Unit::Percent,
        has_history: true,
    },
    Metric {
        id: "memory.used",
        title: "Memory Used",
        unit: Unit::Bytes,
        has_history: false,
    },
    Metric {
        id: "memory.free",
        title: "Memory Free",
        unit: Unit::Bytes,
        has_history: false,
    },
    Metric {
        id: "memory.swap",
        title: "Swap Used",
        unit: Unit::Bytes,
        has_history: false,
    },
    Metric {
        id: "memory.pressure",
        title: "Memory Pressure Level",
        unit: Unit::Level,
        has_history: false,
    },
    Metric {
        id: "memory.commit",
        title: "Committed Memory",
        unit: Unit::Percent,
        has_history: false,
    },
    Metric {
        id: "disk.usage",
        title: "Startup Disk Usage",
        unit: Unit::Percent,
        has_history: false,
    },
    Metric {
        id: "disk.free",
        title: "Startup Disk Free",
        unit: Unit::Bytes,
        has_history: false,
    },
    Metric {
        id: "disk.read",
        title: "Disk Read Speed",
        unit: Unit::BytesPerSecond,
        has_history: true,
    },
    Metric {
        id: "disk.write",
        title: "Disk Write Speed",
        unit: Unit::BytesPerSecond,
        has_history: true,
    },
    Metric {
        id: "disk.totalread",
        title: "Disk Data Read",
        unit: Unit::Bytes,
        has_history: false,
    },
    Metric {
        id: "disk.totalwritten",
        title: "Disk Data Written",
        unit: Unit::Bytes,
        has_history: false,
    },
    Metric {
        id: "disk.smartok",
        title: "Drive S.M.A.R.T. OK",
        unit: Unit::Level,
        has_history: false,
    },
    Metric {
        id: "disk.ssdlife",
        title: "SSD Life Remaining",
        unit: Unit::Percent,
        has_history: false,
    },
    Metric {
        id: "disk.temp",
        title: "Drive Temperature",
        unit: Unit::Celsius,
        has_history: false,
    },
    Metric {
        id: "gpu.usage",
        title: "GPU Usage",
        unit: Unit::Percent,
        has_history: true,
    },
    Metric {
        id: "net.down",
        title: "Download Speed",
        unit: Unit::BytesPerSecond,
        has_history: true,
    },
    Metric {
        id: "net.up",
        title: "Upload Speed",
        unit: Unit::BytesPerSecond,
        has_history: true,
    },
    Metric {
        id: "net.ping",
        title: "WAN Ping",
        unit: Unit::Milliseconds,
        has_history: false,
    },
    Metric {
        id: "net.routerping",
        title: "Router Ping",
        unit: Unit::Milliseconds,
        has_history: false,
    },
    Metric {
        id: "net.totaldown",
        title: "Total Downloaded",
        unit: Unit::Bytes,
        has_history: false,
    },
    Metric {
        id: "net.totalup",
        title: "Total Uploaded",
        unit: Unit::Bytes,
        has_history: false,
    },
    Metric {
        id: "battery.level",
        title: "Battery Level",
        unit: Unit::Percent,
        has_history: false,
    },
    Metric {
        id: "battery.health",
        title: "Battery Health",
        unit: Unit::Percent,
        has_history: false,
    },
    Metric {
        id: "battery.cycles",
        title: "Battery Cycle Count",
        unit: Unit::Count,
        has_history: false,
    },
    Metric {
        id: "battery.temp",
        title: "Battery Temperature",
        unit: Unit::Celsius,
        has_history: false,
    },
    Metric {
        id: "battery.minutesleft",
        title: "Battery Time Remaining",
        unit: Unit::Minutes,
        has_history: false,
    },
    Metric {
        id: "temp.cpu",
        title: "CPU Temperature",
        unit: Unit::Celsius,
        has_history: false,
    },
    Metric {
        id: "temp.gpu",
        title: "GPU Temperature",
        unit: Unit::Celsius,
        has_history: false,
    },
    Metric {
        id: "fan.rpm",
        title: "Fan Speed",
        unit: Unit::Rpm,
        has_history: false,
    },
    Metric {
        id: "system.uptime",
        title: "Uptime",
        unit: Unit::Seconds,
        has_history: false,
    },
    Metric {
        id: "system.thermal",
        title: "Thermal State",
        unit: Unit::Level,
        has_history: false,
    },
];

pub fn find(id: &str) -> Option<&'static Metric> {
    CATALOG.iter().find(|m| m.id.eq_ignore_ascii_case(id))
}

/// The current value, or None where this machine can't say.
pub fn value(id: &str, s: &Snapshot) -> Option<f64> {
    let sysvol = s.disk.system_volume();
    let drive = s.disk.drives.first();
    Some(match id {
        "cpu.usage" => s.cpu.total,
        "cpu.user" => s.cpu.user,
        "cpu.system" => s.cpu.system,
        "cpu.load1" => s.cpu.load?[0],
        "cpu.load5" => s.cpu.load?[1],
        "cpu.load15" => s.cpu.load?[2],
        "memory.usage" => s.memory.usage_pct(),
        "memory.used" => s.memory.used as f64,
        "memory.free" => s.memory.available as f64,
        "memory.swap" => s.memory.swap_used as f64,
        "memory.pressure" => s.memory.pressure as f64,
        "memory.commit" => s.memory.commit_pct(),
        "disk.usage" => sysvol?.usage_pct(),
        "disk.free" => sysvol?.free as f64,
        "disk.read" => s.disk.read_bps as f64,
        "disk.write" => s.disk.write_bps as f64,
        "disk.totalread" => s.disk.total_read as f64,
        "disk.totalwritten" => s.disk.total_written as f64,
        "disk.smartok" => {
            if s.disk.drives.is_empty() {
                return None;
            }
            if s.disk.drives.iter().all(|d| d.is_healthy()) {
                1.0
            } else {
                0.0
            }
        }
        "disk.ssdlife" => drive?.life_remaining()? as f64,
        "disk.temp" => drive?.temperature_c? as f64,
        "gpu.usage" => {
            if !s.gpu.available {
                return None;
            }
            s.gpu.utilization
        }
        "net.down" => s.network.down_bps as f64,
        "net.up" => s.network.up_bps as f64,
        "net.ping" => s.network.ping_ms?,
        "net.routerping" => s.network.router_ping_ms?,
        "net.totaldown" => s.network.total_down as f64,
        "net.totalup" => s.network.total_up as f64,
        "battery.level" if s.battery.present => s.battery.level,
        "battery.health" if s.battery.present => s.battery.health_pct?,
        "battery.cycles" if s.battery.present => s.battery.cycle_count? as f64,
        "battery.temp" if s.battery.present => s.battery.temperature_c?,
        "battery.minutesleft" if s.battery.present => s.battery.minutes_remaining? as f64,
        "temp.cpu" => s.thermal.cpu_c?,
        "temp.gpu" => s.thermal.gpu_c.or(s.gpu.temperature_c)?,
        "fan.rpm" => s.thermal.fans.first()?.rpm as f64,
        "system.uptime" => s.system.uptime_secs as f64,
        "system.thermal" => s.thermal.level.rank() as f64,
        _ => return None,
    })
}

pub fn format_value(unit: Unit, v: f64) -> String {
    use crate::fmt;
    match unit {
        Unit::Percent => format!("{v:.1}%"),
        Unit::Bytes => fmt::total_bytes(v as u64),
        Unit::BytesPerSecond => fmt::speed(v as u64),
        Unit::Milliseconds => fmt::ms(Some(v)),
        Unit::Celsius => fmt::temperature(v),
        Unit::Count => format!("{v:.2}"),
        Unit::Rpm => format!("{v:.0} RPM"),
        Unit::Seconds => fmt::uptime(v as u64),
        Unit::Minutes => fmt::minutes(v as u32),
        Unit::Level => format!("{v:.0}"),
    }
}

#[cfg(test)]
#[allow(clippy::field_reassign_with_default)]
mod tests {
    use super::*;

    #[test]
    fn catalog_ids_are_unique_and_answerable() {
        let s = Snapshot::default();
        for (i, m) in CATALOG.iter().enumerate() {
            assert!(
                CATALOG[i + 1..].iter().all(|o| o.id != m.id),
                "duplicate {}",
                m.id
            );
            let _ = value(m.id, &s); // must not panic
        }
        assert_eq!(value("cpu.usage", &s), Some(0.0));
        assert_eq!(value("battery.level", &s), None);
    }
}
