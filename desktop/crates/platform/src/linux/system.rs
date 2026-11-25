//! Machine identity, CPU topology, language, launch at login (XDG autostart), fonts
//! (fontconfig) and whether the desktop has a system tray.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use super::procfs::{read, read_trim};

/// (model, manufacturer). DMI on PCs; the device tree on a Raspberry Pi; friendly names for
/// Valve's handhelds, whose DMI says "Jupiter"/"Galileo".
pub fn model() -> (String, String) {
    if let Some(m) = read_trim("/proc/device-tree/model") {
        let maker = if m.starts_with("Raspberry Pi") {
            "Raspberry Pi Ltd".to_string()
        } else {
            String::new()
        };
        return (m, maker);
    }
    let dmi = |f: &str| read_trim(Path::new("/sys/class/dmi/id").join(f)).filter(|s| !junk(s));
    // Self-built PCs have placeholders here; the motherboard's name says more.
    let vendor = dmi("sys_vendor")
        .or_else(|| dmi("board_vendor"))
        .unwrap_or_default();
    let product = dmi("product_name")
        .or_else(|| dmi("board_name"))
        .unwrap_or_default();
    let product = match (vendor.as_str(), product.as_str()) {
        ("Valve", "Jupiter") => "Steam Deck".to_string(),
        ("Valve", "Galileo") => "Steam Deck OLED".to_string(),
        // Lenovo keeps the marketing name in product_version.
        ("LENOVO", _) => dmi("product_version").unwrap_or(product),
        _ => product,
    };
    (product, vendor)
}

fn junk(s: &str) -> bool {
    let l = s.to_ascii_lowercase();
    l.contains("to be filled")
        || l.contains("default string")
        || l == "system product name"
        || l == "system manufacturer"
        || l == "none"
}

/// "Cortex-A76" for ARM cores (whose /proc/cpuinfo has no model name).
pub fn cpu_model() -> Option<String> {
    let info = read("/proc/cpuinfo")?;
    if let Some(n) = info
        .lines()
        .find_map(|l| {
            l.strip_prefix("model name")
                .and_then(|r| r.split_once(':'))
                .map(|(_, v)| v.trim())
        })
        .filter(|v| !v.is_empty())
    {
        return Some(n.to_string());
    }
    let implementer = field(&info, "CPU implementer")?;
    let parts: BTreeSet<String> = info
        .lines()
        .filter_map(|l| {
            l.strip_prefix("CPU part")
                .and_then(|r| r.split_once(':'))
                .map(|(_, v)| v.trim().to_string())
        })
        .collect();
    let names: Vec<&str> = parts.iter().filter_map(|p| arm_core(&implementer, p)).collect();
    (!names.is_empty()).then(|| names.join(" + "))
}

fn field(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|l| {
        l.strip_prefix(key)
            .and_then(|r| r.split_once(':'))
            .map(|(_, v)| v.trim().to_string())
    })
}

pub fn arm_core(implementer: &str, part: &str) -> Option<&'static str> {
    if implementer != "0x41" {
        return match (implementer, part) {
            ("0x51", _) => Some("Qualcomm Oryon"),
            ("0x61", _) => Some("Apple"),
            _ => None,
        };
    }
    Some(match part {
        "0xd03" => "Cortex-A53",
        "0xd04" => "Cortex-A35",
        "0xd05" => "Cortex-A55",
        "0xd07" => "Cortex-A57",
        "0xd08" => "Cortex-A72",
        "0xd09" => "Cortex-A73",
        "0xd0a" => "Cortex-A75",
        "0xd0b" => "Cortex-A76",
        "0xd0d" => "Cortex-A77",
        "0xd41" => "Cortex-A78",
        "0xd46" => "Cortex-A510",
        "0xd47" => "Cortex-A710",
        "0xd48" => "Cortex-X2",
        "0xd4d" => "Cortex-A715",
        "0xd4e" => "Cortex-X3",
        "0xd80" => "Cortex-A520",
        "0xd81" => "Cortex-A720",
        "0xd82" => "Cortex-X4",
        "0xd0c" => "Neoverse N1",
        "0xd40" => "Neoverse V1",
        _ => return None,
    })
}

/// (physical cores, performance cores, efficiency cores). Intel hybrid parts list their P- and
/// E-cores under /sys/devices/cpu_core and cpu_atom; ARM big.LITTLE shows as differing
/// `cpu_capacity`.
pub fn core_topology() -> (usize, usize, usize) {
    let cpus = online_cpus();
    let mut cores: BTreeSet<(String, String)> = BTreeSet::new();
    let mut capacity: Vec<(usize, u64, (String, String))> = Vec::new();
    for c in &cpus {
        let topo = PathBuf::from(format!("/sys/devices/system/cpu/cpu{c}/topology"));
        let key = (
            read_trim(topo.join("physical_package_id")).unwrap_or_default(),
            read_trim(topo.join("core_id")).unwrap_or_else(|| c.to_string()),
        );
        cores.insert(key.clone());
        if let Some(cap) =
            read_trim(format!("/sys/devices/system/cpu/cpu{c}/cpu_capacity")).and_then(|s| s.parse().ok())
        {
            capacity.push((*c, cap, key));
        }
    }
    let physical = cores.len();
    if let (Some(p), Some(e)) = (
        read_trim("/sys/devices/cpu_core/cpus").map(|s| parse_cpu_list(&s)),
        read_trim("/sys/devices/cpu_atom/cpus").map(|s| parse_cpu_list(&s)),
    ) {
        let p_cores: BTreeSet<_> = capacity_keys(&p);
        return (physical, p_cores.len(), e.len());
    }
    if capacity.len() == cpus.len() && !capacity.is_empty() {
        let max = capacity.iter().map(|c| c.1).max().unwrap_or(0);
        let min = capacity.iter().map(|c| c.1).min().unwrap_or(0);
        if max != min {
            let p: BTreeSet<_> = capacity
                .iter()
                .filter(|c| c.1 == max)
                .map(|c| c.2.clone())
                .collect();
            return (physical, p.len(), physical.saturating_sub(p.len()));
        }
    }
    (physical, physical, 0)
}

fn capacity_keys(cpus: &[usize]) -> BTreeSet<(String, String)> {
    cpus.iter()
        .map(|c| {
            let topo = PathBuf::from(format!("/sys/devices/system/cpu/cpu{c}/topology"));
            (
                read_trim(topo.join("physical_package_id")).unwrap_or_default(),
                read_trim(topo.join("core_id")).unwrap_or_else(|| c.to_string()),
            )
        })
        .collect()
}

fn online_cpus() -> Vec<usize> {
    read_trim("/sys/devices/system/cpu/online")
        .map(|s| parse_cpu_list(&s))
        .unwrap_or_default()
}

/// "0-3,8,10-11" → [0,1,2,3,8,10,11]
pub fn parse_cpu_list(s: &str) -> Vec<usize> {
    let mut v = Vec::new();
    for part in s.trim().split(',').filter(|p| !p.is_empty()) {
        match part.split_once('-') {
            Some((a, b)) => {
                if let (Ok(a), Ok(b)) = (a.parse::<usize>(), b.parse::<usize>()) {
                    v.extend(a..=b);
                }
            }
            None => v.extend(part.parse::<usize>().ok()),
        }
    }
    v
}

/// The user's UI language as a BCP-47 tag ("de-DE"), from the usual locale variables.
pub fn ui_language() -> String {
    let raw = std::env::var("LANGUAGE")
        .ok()
        .and_then(|l| l.split(':').next().map(str::to_string))
        .filter(|l| !l.is_empty())
        .or_else(|| std::env::var("LC_ALL").ok().filter(|v| !v.is_empty()))
        .or_else(|| std::env::var("LC_MESSAGES").ok().filter(|v| !v.is_empty()))
        .or_else(|| std::env::var("LANG").ok())
        .unwrap_or_default();
    locale_to_bcp47(&raw)
}

pub fn locale_to_bcp47(raw: &str) -> String {
    let base = raw.split(['.', '@']).next().unwrap_or("");
    if base == "C" || base == "POSIX" {
        return "en-US".into();
    }
    base.replace('_', "-")
}

fn autostart_file() -> Option<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(config.join("autostart").join("com.blainemiller.Blip.desktop"))
}

pub fn launch_at_login() -> bool {
    autostart_file().is_some_and(|f| f.exists())
}

/// XDG autostart entry: honoured by GNOME, KDE (and SteamOS desktop mode), Xfce, LXQt,
/// Cinnamon, MATE and Raspberry Pi OS's labwc/LXDE sessions.
pub fn set_launch_at_login(enabled: bool) -> Result<(), String> {
    let file = autostart_file().ok_or("No home directory.")?;
    if !enabled {
        return match std::fs::remove_file(&file) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.to_string()),
        };
    }
    let exe = std::env::var_os("APPIMAGE")
        .map(PathBuf::from)
        .or_else(|| std::env::current_exe().ok())
        .ok_or("Couldn't find Blip's executable.")?;
    let text = format!(
        "[Desktop Entry]\nType=Application\nName=Blip\nComment=System monitor\nExec=\"{}\" --background\nIcon=com.blainemiller.Blip\nTerminal=false\nX-GNOME-Autostart-enabled=true\nX-GNOME-Autostart-Delay=3\n",
        exe.display()
    );
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    std::fs::write(&file, text).map_err(|e| e.to_string())
}

/// A font file fontconfig picks for `pattern` (what every toolkit on the desktop would use).
pub fn fc_match(pattern: &str) -> Option<PathBuf> {
    let out = std::process::Command::new("fc-match")
        .args(["-f", "%{file}", pattern])
        .output()
        .ok()?;
    let p = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
    // egui reads TrueType/OpenType only.
    let ext = p.extension()?.to_string_lossy().to_ascii_lowercase();
    (p.exists() && matches!(ext.as_str(), "ttf" | "otf" | "ttc")).then_some(p)
}

/// Whether a StatusNotifierItem host (the tray) is running: KDE Plasma and SteamOS desktop mode,
/// Ubuntu's GNOME (AppIndicator extension), Xfce, Cinnamon, MATE, LXQt, and Raspberry Pi OS's
/// wf-panel-pi. Stock GNOME without the extension has none.
pub fn tray_host_available() -> bool {
    super::bus::session().is_some_and(|c| super::bus::has_owner(c, "org.kde.StatusNotifierWatcher"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_lists() {
        assert_eq!(parse_cpu_list("0-3,8,10-11\n"), vec![0, 1, 2, 3, 8, 10, 11]);
        assert_eq!(parse_cpu_list("0"), vec![0]);
    }

    #[test]
    fn locales() {
        assert_eq!(locale_to_bcp47("de_DE.UTF-8"), "de-DE");
        assert_eq!(locale_to_bcp47("pt_BR@euro"), "pt-BR");
        assert_eq!(locale_to_bcp47("C.UTF-8"), "en-US");
    }

    #[test]
    fn arm_cores() {
        assert_eq!(arm_core("0x41", "0xd0b"), Some("Cortex-A76"));
        assert_eq!(arm_core("0x41", "0xfff"), None);
    }
}
