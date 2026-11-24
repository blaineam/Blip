//! Battery from /sys/class/power_supply (the kernel's own view, what UPower reads too):
//! charge, wear, cycles, power draw and time left. Battery saver is power-profiles-daemon's
//! "power-saver" profile.

use std::path::Path;
use std::time::Instant;

use blip_core::model::BatteryStats;

use super::procfs::{read_i64, read_trim, read_u64};

#[derive(Default)]
pub struct BatterySampler {
    saver: bool,
    saver_at: Option<Instant>,
}

impl BatterySampler {
    pub fn new() -> Self {
        Self {
            saver: false,
            saver_at: None,
        }
    }

    pub fn sample(&mut self, out: &mut BatteryStats) {
        let Ok(rd) = std::fs::read_dir("/sys/class/power_supply") else {
            return;
        };
        let mut supplies: Vec<_> = rd.flatten().map(|e| e.path()).collect();
        supplies.sort();
        let mut battery = None;
        let mut ac_online = false;
        for p in &supplies {
            let kind = read_trim(p.join("type")).unwrap_or_default();
            match kind.as_str() {
                // Mice and headsets report scope=Device; only system batteries count.
                "Battery" if read_trim(p.join("scope")).as_deref() != Some("Device") => {
                    if battery.is_none() && read_u64(p.join("present")).unwrap_or(1) == 1 {
                        battery = Some(p.clone());
                    }
                }
                "Mains" | "USB" | "USB_C" | "USB_PD" => {
                    ac_online |= read_u64(p.join("online")).unwrap_or(0) == 1;
                }
                _ => {}
            }
        }
        let Some(b) = battery else { return };
        fill(&b, ac_online, out);
        if out.present {
            if self.saver_at.is_none_or(|t| t.elapsed().as_secs() >= 10) {
                self.saver = power_saver();
                self.saver_at = Some(Instant::now());
            }
            out.battery_saver = self.saver;
        }
    }
}

fn fill(b: &Path, ac_online: bool, out: &mut BatteryStats) {
    let status = read_trim(b.join("status")).unwrap_or_default();
    let Some(level) = read_u64(b.join("capacity"))
        .map(|v| v.min(100) as f64)
        .or_else(|| {
            let now = read_u64(b.join("energy_now")).or_else(|| read_u64(b.join("charge_now")))?;
            let full = read_u64(b.join("energy_full")).or_else(|| read_u64(b.join("charge_full")))?;
            (full > 0).then(|| (now as f64 / full as f64 * 100.0).min(100.0))
        })
    else {
        return;
    };
    out.present = true;
    out.level = level;
    out.charging = status == "Charging";
    out.plugged_in = ac_online || matches!(status.as_str(), "Charging" | "Full" | "Not charging");

    // Energy in µWh, or charge in µAh × design voltage in µV.
    let volts_design = read_u64(b.join("voltage_min_design")).filter(|v| *v > 0);
    let to_mwh = |energy: &str, charge: &str| -> Option<u64> {
        read_u64(b.join(energy))
            .map(|uwh| uwh / 1000)
            .or_else(|| Some(read_u64(b.join(charge))? * volts_design? / 1_000_000_000))
            .filter(|v| *v > 0)
    };
    let design = to_mwh("energy_full_design", "charge_full_design");
    let full = to_mwh("energy_full", "charge_full");
    let now = to_mwh("energy_now", "charge_now");
    out.design_capacity_mwh = design.map(|v| v as u32);
    out.full_capacity_mwh = full.map(|v| v as u32);
    if let (Some(d), Some(f)) = (design, full) {
        out.health_pct = Some((f as f64 / d as f64 * 100.0).min(100.0));
    }
    out.cycle_count = read_u64(b.join("cycle_count"))
        .filter(|c| *c > 0)
        .map(|c| c as u32);
    out.chemistry = read_trim(b.join("technology")).filter(|t| t != "Unknown");
    out.temperature_c = read_i64(b.join("temp")).map(|t| t as f64 / 10.0);

    // Power in µW, or current µA × voltage µV. Positive = charging, like Windows' rate.
    let watts_mw = read_i64(b.join("power_now"))
        .map(|uw| uw.abs() / 1000)
        .or_else(|| {
            let ua = read_i64(b.join("current_now"))?.abs();
            let uv = read_i64(b.join("voltage_now"))?.abs();
            Some(ua * uv / 1_000_000_000)
        });
    if let Some(mw) = watts_mw.filter(|w| *w > 0) {
        let signed = if out.charging {
            mw
        } else if status == "Discharging" {
            -mw
        } else {
            0
        };
        out.rate_mw = Some(signed as i32);
        if status == "Discharging" {
            if let Some(n) = now {
                out.minutes_remaining = Some((n as f64 / mw as f64 * 60.0) as u32);
            }
        }
    }
}

/// power-profiles-daemon's active profile (GNOME/KDE "Power Saver"); its newer name first.
fn power_saver() -> bool {
    let Some(c) = super::bus::system() else {
        return false;
    };
    [
        (
            "org.freedesktop.UPower.PowerProfiles",
            "/org/freedesktop/UPower/PowerProfiles",
        ),
        ("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles"),
    ]
    .iter()
    .find_map(|(name, path)| super::bus::prop::<String>(c, name, path, name, "ActiveProfile"))
    .is_some_and(|p| p == "power-saver")
}
