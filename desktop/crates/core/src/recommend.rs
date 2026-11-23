//! Dismissable, actionable suggestions — a port of the Mac `RecommendationsEngine`, with the
//! system-process list swapped for Windows' (and Linux's) own.

use crate::fmt;
use crate::i18n::{t, tf};
use crate::model::{Snapshot, ThermalLevel};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Severity {
    Info = 0,
    Warning = 1,
    Critical = 2,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Recommendation {
    /// Stable across polls so a dismissal sticks.
    pub id: String,
    pub severity: Severity,
    pub icon: crate::Icon,
    pub title: String,
    pub detail: String,
}

/// Processes Blip never suggests quitting, even when they're the CPU hog.
const SYSTEM_PROCESSES: &[&str] = &[
    // Windows
    "system",
    "registry",
    "smss.exe",
    "csrss.exe",
    "wininit.exe",
    "winlogon.exe",
    "services.exe",
    "lsass.exe",
    "svchost.exe",
    "dwm.exe",
    "explorer.exe",
    "fontdrvhost.exe",
    "sihost.exe",
    "taskhostw.exe",
    "runtimebroker.exe",
    "searchhost.exe",
    "searchindexer.exe",
    "msmpeng.exe",
    "memory compression",
    "audiodg.exe",
    "spoolsv.exe",
    "wmiprvse.exe",
    "ctfmon.exe",
    "startmenuexperiencehost.exe",
    "shellexperiencehost.exe",
    "textinputhost.exe",
    "securityhealthservice.exe",
    "trustedinstaller.exe",
    "tiworker.exe",
    "conhost.exe",
    "system idle process",
    "secure system",
    "mpdefendercoreservice.exe",
    "smartscreen.exe",
    "widgets.exe",
    "phoneexperiencehost.exe",
    "lockapp.exe",
    "systemsettings.exe",
    // Linux
    "systemd",
    "kthreadd",
    "xorg",
    "xwayland",
    "gnome-shell",
    "kwin_wayland",
    "kwin_x11",
    "plasmashell",
    "pipewire",
    "pulseaudio",
    "dbus-daemon",
    "networkmanager",
    "journald",
    "systemd-journald",
    "gamescope",
    "steamwebhelper",
];

pub fn is_system_process(name: &str) -> bool {
    SYSTEM_PROCESSES.contains(&name.to_ascii_lowercase().as_str())
}

pub fn analyze(s: &Snapshot) -> Vec<Recommendation> {
    use crate::Icon;
    let mut recs = Vec::new();

    if let Some(p) = s
        .top_cpu
        .iter()
        .find(|p| p.cpu > 85.0 && p.user_owned && !is_system_process(&p.name))
    {
        recs.push(Recommendation {
            id: "cpu-hog".into(),
            severity: Severity::Warning,
            icon: Icon::Cpu,
            title: tf(
                "%@ is using %lld%% CPU",
                &[&display_name(&p.name), &(p.cpu as i64)],
            ),
            detail: t("Quitting or restarting it would cut heat, fan noise, and battery drain."),
        });
    }

    if s.memory.pressure >= 2 {
        recs.push(Recommendation {
            id: "mem-pressure".into(),
            severity: Severity::Critical,
            icon: Icon::Memory,
            title: t("Memory pressure is high"),
            detail: t(
                "Close some apps or browser tabs — heavy swapping wears the SSD and slows things down.",
            ),
        });
    } else if s.memory.swap_used > 3_000_000_000 {
        recs.push(Recommendation {
            id: "mem-swap".into(),
            severity: Severity::Warning,
            icon: Icon::Memory,
            title: tf(
                "%@ of swap in use",
                &[&format!("{:.1} GB", s.memory.swap_used as f64 / 1e9)],
            ),
            detail: t("Frequent swapping adds SSD writes. Closing memory-hungry apps helps."),
        });
    }

    let level = s.thermal.level;
    if level >= ThermalLevel::Serious {
        recs.push(Recommendation {
            id: "thermal".into(),
            severity: if level == ThermalLevel::Critical {
                Severity::Critical
            } else {
                Severity::Warning
            },
            icon: Icon::Thermometer,
            title: tf("Your PC is running hot (%@)", &[&t(level.english())]),
            detail: t("Reduce load, improve airflow, or move off soft surfaces to avoid throttling."),
        });
    }

    if let Some(v) = s.disk.system_volume() {
        if v.usage_pct() > 90.0 {
            recs.push(Recommendation {
                id: "disk-full".into(),
                severity: Severity::Warning,
                icon: Icon::Disk,
                title: tf("Startup disk is %lld%% full", &[&(v.usage_pct() as i64)]),
                detail: t(
                    "Free up space — a nearly-full SSD slows down and has less room for wear-leveling.",
                ),
            });
        }
    }

    for d in &s.disk.drives {
        if !d.is_healthy() {
            recs.push(Recommendation {
                id: format!("smart-{}", d.id),
                severity: Severity::Critical,
                icon: Icon::Warning,
                title: tf("%@ reports a S.M.A.R.T. warning", &[&d.name]),
                detail: t("Back up this drive now — it may be failing."),
            });
        } else if let Some(life) = d.life_remaining().filter(|l| *l < 20) {
            recs.push(Recommendation {
                id: format!("ssd-life-{}", d.id),
                severity: Severity::Warning,
                icon: Icon::Disk,
                title: tf("%@ is at %lld%% life remaining", &[&d.name, &life]),
                detail: t("The SSD is wearing out — keep backups and plan a replacement."),
            });
        }
    }

    if s.battery.present {
        if let Some(h) = s.battery.health_pct.filter(|h| *h > 0.0 && *h < 80.0) {
            recs.push(Recommendation {
                id: "batt-health".into(),
                severity: Severity::Info,
                icon: Icon::Battery,
                title: tf("Battery health is %lld%%", &[&(h as i64)]),
                detail: t("Capacity has dropped — a battery service would restore runtime."),
            });
        }
    }

    let _ = fmt::percent; // keep the formatter import honest if strings change
    recs.sort_by_key(|r| std::cmp::Reverse(r.severity));
    recs
}

/// "chrome.exe" → "chrome" for prose; Linux names pass through.
pub fn display_name(name: &str) -> String {
    name.strip_suffix(".exe")
        .or_else(|| name.strip_suffix(".EXE"))
        .unwrap_or(name)
        .to_string()
}

#[cfg(test)]
#[allow(clippy::field_reassign_with_default)]
mod tests {
    use super::*;
    use crate::model::*;

    #[test]
    fn runaway_user_app_but_never_system() {
        let mut s = Snapshot::default();
        s.top_cpu = vec![
            ProcessInfo {
                pid: 4,
                name: "svchost.exe".into(),
                cpu: 99.0,
                user_owned: true,
                ..Default::default()
            },
            ProcessInfo {
                pid: 9,
                name: "chrome.exe".into(),
                cpu: 97.0,
                user_owned: true,
                ..Default::default()
            },
        ];
        let recs = analyze(&s);
        assert_eq!(recs.len(), 1);
        assert_eq!(recs[0].title, "chrome is using 97% CPU");
    }

    #[test]
    fn critical_sorts_first() {
        let mut s = Snapshot::default();
        s.memory.pressure = 2;
        s.battery.present = true;
        s.battery.health_pct = Some(70.0);
        s.disk.drives.push(DriveHealth {
            id: "0".into(),
            name: "NVMe".into(),
            critical_warning: Some(1),
            ..Default::default()
        });
        let recs = analyze(&s);
        assert_eq!(recs.first().map(|r| r.severity), Some(Severity::Critical));
        assert_eq!(recs.last().map(|r| r.severity), Some(Severity::Info));
    }
}
