//! Machine identity, language, autostart and shell helpers.

use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Globalization::{GetUserDefaultUILanguage, LCIDToLocaleName};
use windows::Win32::System::Power::{GetPwrCapabilities, SYSTEM_POWER_CAPABILITIES};
use windows::Win32::System::Registry::*;
use windows::Win32::System::SystemInformation::*;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

const RUN_KEY: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");

pub fn reg_string(root: HKEY, key: &str, value: &str) -> Option<String> {
    let (k, v) = (HSTRING::from(key), HSTRING::from(value));
    let mut size = 0u32;
    // SAFETY: size query, then a read into a buffer of that size.
    unsafe {
        if RegGetValueW(root, &k, &v, RRF_RT_REG_SZ, None, None, Some(&mut size)).0 != 0 || size == 0 {
            return None;
        }
        let mut buf = vec![0u16; size as usize / 2 + 1];
        if RegGetValueW(root, &k, &v, RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as _), Some(&mut size)).0 != 0 {
            return None;
        }
        let len = buf.iter().position(|c| *c == 0).unwrap_or(buf.len());
        Some(String::from_utf16_lossy(&buf[..len]).trim().to_string()).filter(|s| !s.is_empty())
    }
}

pub fn reg_dword(root: HKEY, key: &str, value: &str) -> Option<u32> {
    let (k, v) = (HSTRING::from(key), HSTRING::from(value));
    let mut data = 0u32;
    let mut size = 4u32;
    // SAFETY: DWORD out-param.
    let rc = unsafe { RegGetValueW(root, &k, &v, RRF_RT_REG_DWORD, None, Some(&mut data as *mut u32 as _), Some(&mut size)) };
    (rc.0 == 0).then_some(data)
}

pub fn ui_language() -> String {
    let mut buf = [0u16; 85];
    // SAFETY: fixed buffer of LOCALE_NAME_MAX_LENGTH.
    let n = unsafe { LCIDToLocaleName(GetUserDefaultUILanguage() as u32, Some(&mut buf), 0) };
    if n <= 1 {
        return String::new();
    }
    String::from_utf16_lossy(&buf[..n as usize - 1])
}

/// "Windows 11 Pro", "24H2 (26100.2605)".
pub fn os_name_version() -> (String, String) {
    let key = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
    let mut name = reg_string(HKEY_LOCAL_MACHINE, key, "ProductName").unwrap_or_else(|| "Windows".into());
    let build: u32 = reg_string(HKEY_LOCAL_MACHINE, key, "CurrentBuildNumber").and_then(|b| b.parse().ok()).unwrap_or(0);
    // ProductName still says "Windows 10" on Windows 11.
    if build >= 22000 {
        name = name.replace("Windows 10", "Windows 11");
    }
    let display = reg_string(HKEY_LOCAL_MACHINE, key, "DisplayVersion").unwrap_or_default();
    let ubr = reg_dword(HKEY_LOCAL_MACHINE, key, "UBR").unwrap_or(0);
    let version = if display.is_empty() { format!("{build}.{ubr}") } else { format!("{display} ({build}.{ubr})") };
    (name, version)
}

/// (model, manufacturer) from the firmware tables Windows mirrors into the registry.
pub fn model() -> (String, String) {
    let key = "HARDWARE\\DESCRIPTION\\System\\BIOS";
    let product = reg_string(HKEY_LOCAL_MACHINE, key, "SystemProductName").unwrap_or_default();
    let family = reg_string(HKEY_LOCAL_MACHINE, key, "SystemFamily").unwrap_or_default();
    let maker = reg_string(HKEY_LOCAL_MACHINE, key, "SystemManufacturer").unwrap_or_default();
    let junk = |s: &str| s.is_empty() || s.to_ascii_lowercase().contains("to be filled") || s.eq_ignore_ascii_case("system product name") || s.eq_ignore_ascii_case("default string");
    // Lenovo puts the marketing name in SystemFamily ("ThinkPad X1 Carbon Gen 11").
    let model = if maker.eq_ignore_ascii_case("LENOVO") && !junk(&family) { family } else if junk(&product) { String::new() } else { product };
    (model, if junk(&maker) { String::new() } else { maker })
}

pub fn cpu_model() -> Option<String> {
    reg_string(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "ProcessorNameString")
}

/// (physical cores, performance cores, efficiency cores). Hybrid parts report two
/// efficiency classes; the higher one is the P-cores.
pub fn core_topology() -> (usize, usize, usize) {
    let mut len = 0u32;
    // SAFETY: size query, then fill.
    unsafe {
        let _ = GetLogicalProcessorInformationEx(RelationProcessorCore, None, &mut len);
        if len == 0 {
            return (0, 0, 0);
        }
        let mut buf = vec![0u64; (len as usize).div_ceil(8)];
        if GetLogicalProcessorInformationEx(RelationProcessorCore, Some(buf.as_mut_ptr() as _), &mut len).is_err() {
            return (0, 0, 0);
        }
        let bytes = std::slice::from_raw_parts(buf.as_ptr() as *const u8, len as usize);
        let mut classes = Vec::new();
        let mut off = 0usize;
        while off + 10 <= bytes.len() {
            let size = u32::from_le_bytes(bytes[off + 4..off + 8].try_into().unwrap()) as usize;
            if size == 0 {
                break;
            }
            classes.push(bytes[off + 9]);
            off += size;
        }
        let max = classes.iter().copied().max().unwrap_or(0);
        let min = classes.iter().copied().min().unwrap_or(0);
        if max == min {
            (classes.len(), classes.len(), 0)
        } else {
            let p = classes.iter().filter(|c| **c == max).count();
            (classes.len(), p, classes.len() - p)
        }
    }
}

pub fn has_lid() -> bool {
    let mut caps = SYSTEM_POWER_CAPABILITIES::default();
    // SAFETY: out-param.
    unsafe { GetPwrCapabilities(&mut caps) && caps.LidPresent }
}

pub fn uptime_secs() -> u64 {
    // SAFETY: no arguments.
    unsafe { GetTickCount64() / 1000 }
}

fn exe_command() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    Some(format!("\"{}\" --background", exe.display()))
}

pub fn launch_at_login() -> bool {
    match (reg_string(HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\CurrentVersion\\Run", "Blip"), exe_command()) {
        (Some(v), Some(me)) => v.eq_ignore_ascii_case(&me),
        _ => false,
    }
}

pub fn set_launch_at_login(enabled: bool) -> Result<(), String> {
    // SAFETY: HKCU writes with valid buffers.
    unsafe {
        if enabled {
            let cmd = exe_command().ok_or("Couldn't find Blip.exe")?;
            let w: Vec<u16> = cmd.encode_utf16().chain(std::iter::once(0)).collect();
            let rc = RegSetKeyValueW(HKEY_CURRENT_USER, RUN_KEY, w!("Blip"), REG_SZ.0, Some(w.as_ptr() as _), (w.len() * 2) as u32);
            if rc.0 != 0 {
                return Err(format!("Couldn't write the Run key ({})", rc.0));
            }
        } else {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, w!("Blip"));
        }
    }
    Ok(())
}

pub fn shell_open(target: &str) {
    let t = HSTRING::from(target);
    // SAFETY: open verb on a URL/path.
    unsafe {
        ShellExecuteW(None, w!("open"), &t, None, None, SW_SHOWNORMAL);
    }
}
