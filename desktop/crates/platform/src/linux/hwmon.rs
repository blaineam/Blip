//! Sensors from /sys/class/hwmon and /sys/class/thermal: CPU package, GPU and drive
//! temperatures, and fan RPM. All of it is world-readable, so unlike Windows the Linux build
//! shows real fan speeds and die temperatures without a driver.

use std::path::{Path, PathBuf};

use blip_core::model::Fan;

use super::procfs::{read_i64, read_trim, read_u64};

#[derive(Debug, Clone, Default)]
pub struct Sensors {
    pub cpu_c: Option<f64>,
    pub gpu_c: Option<f64>,
    /// Thermal zones and other named sensors (label, °C).
    pub zones: Vec<(String, f64)>,
    pub fans: Vec<Fan>,
    /// Drive temperatures keyed by the canonical sysfs path of the drive's device.
    pub drives: Vec<(PathBuf, f64)>,
}

/// hwmon chips that measure the CPU, best first.
const CPU_CHIPS: &[&str] = &[
    "coretemp",
    "k10temp",
    "zenpower",
    "cpu_thermal",
    "cpu-thermal",
    "soc_thermal",
    "cpu0_thermal",
    "thinkpad",
    "acpitz",
];
const GPU_CHIPS: &[&str] = &["amdgpu", "nouveau", "radeon", "i915", "xe"];
const DRIVE_CHIPS: &[&str] = &["nvme", "drivetemp"];

fn temp_c(p: &Path) -> Option<f64> {
    let m = read_i64(p)?;
    let c = m as f64 / 1000.0;
    (-30.0..150.0).contains(&c).then_some(c)
}

/// The CPU reading a chip offers: the package/die sensor if labelled, else its first input.
fn cpu_reading(dir: &Path, chip: &str) -> Option<f64> {
    let mut first = None;
    for i in 1..=32 {
        let input = dir.join(format!("temp{i}_input"));
        if !input.exists() {
            continue;
        }
        let Some(c) = temp_c(&input) else { continue };
        let label = read_trim(dir.join(format!("temp{i}_label"))).unwrap_or_default();
        let l = label.to_ascii_lowercase();
        if l.starts_with("package") || l == "tctl" || l == "tdie" || (chip == "thinkpad" && l == "cpu") {
            return Some(c);
        }
        first.get_or_insert(c);
    }
    first
}

pub fn read_sensors() -> Sensors {
    let mut out = Sensors::default();
    let mut cpu: Option<(usize, f64)> = None;
    let Ok(rd) = std::fs::read_dir("/sys/class/hwmon") else {
        return out;
    };
    let mut dirs: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
    dirs.sort();
    for dir in dirs {
        let chip = read_trim(dir.join("name")).unwrap_or_default();
        if let Some(rank) = CPU_CHIPS.iter().position(|c| *c == chip) {
            if let Some(c) = cpu_reading(&dir, &chip) {
                if cpu.is_none_or(|(r, _)| rank < r) {
                    cpu = Some((rank, c));
                }
            }
        }
        if GPU_CHIPS.contains(&chip.as_str()) && out.gpu_c.is_none() {
            out.gpu_c = temp_c(&dir.join("temp1_input"));
        }
        if DRIVE_CHIPS.contains(&chip.as_str()) {
            if let (Some(c), Ok(dev)) = (
                temp_c(&dir.join("temp1_input")),
                std::fs::canonicalize(dir.join("device")),
            ) {
                out.drives.push((dev, c));
            }
        }
        for i in 1..=8 {
            let Some(rpm) = read_u64(dir.join(format!("fan{i}_input"))) else {
                continue;
            };
            let label = read_trim(dir.join(format!("fan{i}_label")));
            let name = match (label, chip.as_str()) {
                (Some(l), _) => l,
                (None, "amdgpu" | "nouveau" | "radeon") => "GPU".to_string(),
                (None, "pwmfan" | "cooling_fan") => "Fan".to_string(),
                (None, c) if i == 1 => pretty_chip(c),
                (None, c) => format!("{} {i}", pretty_chip(c)),
            };
            out.fans.push(Fan {
                name,
                rpm: rpm as u32,
                min_rpm: read_u64(dir.join(format!("fan{i}_min")))
                    .filter(|v| *v > 0)
                    .map(|v| v as u32),
                max_rpm: read_u64(dir.join(format!("fan{i}_max")))
                    .filter(|v| *v > 0)
                    .map(|v| v as u32),
            });
        }
    }
    out.cpu_c = cpu.map(|c| c.1);
    out.zones = thermal_zones();
    if out.cpu_c.is_none() {
        out.cpu_c = out
            .zones
            .iter()
            .find(|(n, _)| {
                let n = n.to_ascii_lowercase();
                n.contains("cpu") || n.contains("x86_pkg") || n.contains("soc")
            })
            .map(|z| z.1);
    }
    out
}

fn pretty_chip(c: &str) -> String {
    match c {
        "thinkpad" => "ThinkPad".into(),
        "dell_smm" => "Dell".into(),
        "asus" | "asus_wmi_sensors" | "asus-ec-sensors" => "ASUS".into(),
        "steamdeck_hwmon" | "jupiter" => "Steam Deck".into(),
        other => {
            let mut c = other.chars();
            c.next()
                .map(|f| f.to_uppercase().collect::<String>() + c.as_str())
                .unwrap_or_default()
        }
    }
}

/// /sys/class/thermal zones (the ACPI and SoC zones Windows shows as "Thermal Zone").
pub fn thermal_zones() -> Vec<(String, f64)> {
    let mut v = Vec::new();
    let Ok(rd) = std::fs::read_dir("/sys/class/thermal") else {
        return v;
    };
    let mut dirs: Vec<PathBuf> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with("thermal_zone"))
        })
        .collect();
    dirs.sort();
    for d in dirs {
        let name = read_trim(d.join("type")).unwrap_or_else(|| "zone".into());
        if let Some(c) = temp_c(&d.join("temp")).filter(|c| *c > 5.0) {
            v.push((name, c));
        }
    }
    v
}

/// Average current clock across cores, and the base clock it should be compared with.
pub fn cpu_clocks() -> (Option<u64>, Option<u64>) {
    let mut sum = 0u64;
    let mut n = 0u64;
    let mut base = None;
    let Ok(rd) = std::fs::read_dir("/sys/devices/system/cpu") else {
        return (None, None);
    };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if !name.starts_with("cpu") || !name[3..].chars().all(|c| c.is_ascii_digit()) || name.len() == 3 {
            continue;
        }
        let f = e.path().join("cpufreq");
        if let Some(khz) = read_u64(f.join("scaling_cur_freq")) {
            sum += khz;
            n += 1;
        }
        if base.is_none() {
            // intel_pstate exposes the real base clock; amd-pstate its nominal one. Otherwise the
            // policy max (on ARM SoCs that *is* the rated clock).
            base = read_u64(f.join("base_frequency"))
                .or_else(|| read_u64(f.join("amd_pstate_nominal_freq")))
                .or_else(|| read_u64(f.join("cpuinfo_max_freq")));
        }
    }
    let cur = (n > 0).then(|| sum / n / 1000);
    (cur.filter(|c| *c > 0), base.map(|b| b / 1000).filter(|b| *b > 0))
}

/// Package throttle events (Intel) — a counter that only grows while the CPU is held back.
pub fn throttle_events() -> Option<u64> {
    let mut total = None;
    let rd = std::fs::read_dir("/sys/devices/system/cpu").ok()?;
    for e in rd.flatten() {
        let p = e.path().join("thermal_throttle/package_throttle_count");
        if let Some(v) = read_u64(&p) {
            *total.get_or_insert(0) += v;
        }
    }
    total
}

/// Raspberry Pi firmware throttle flags (the bits `vcgencmd get_throttled` prints): bit 1 = ARM
/// clock capped, bit 2 = throttled now, bit 3 = soft temperature limit. `None` off a Pi.
pub fn pi_throttled() -> Option<bool> {
    const PATHS: &[&str] = &[
        "/sys/devices/platform/soc/soc:firmware/get_throttled",
        "/sys/devices/platform/axi/axi:firmware/get_throttled",
        "/sys/devices/platform/firmware/get_throttled",
    ];
    let v = PATHS.iter().find_map(read_trim)?;
    let bits = u32::from_str_radix(v.trim_start_matches("0x"), 16).ok()?;
    Some(bits & 0b1110 != 0)
}
