//! Per-user install on Windows, no admin (the same flow as Glint): `Blip.exe` copies itself and
//! `blip-cli.exe` to `%LOCALAPPDATA%\Programs\Blip`, adds a Start menu shortcut, starts at
//! login, puts the folder on the user's PATH (for `blip-cli`), and registers in Settings › Apps
//! (the per-user Uninstall key) so it can be removed like any app. Running a newer downloaded
//! exe offers to update the installed copy; running the same or an older one opens the installed
//! copy. Choosing "No" keeps Blip portable, and Settings offers to install later.
//!
//! Command line: `--install` (no questions), `--uninstall [--quiet]`, `--portable` (skip the
//! offer once), `--wait <pid>` (let a previous instance exit first; used when handing over).

use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use blip_core::{t, tf};
use windows::core::{w, Interface, HSTRING};
use windows::Win32::Foundation::{CloseHandle, LPARAM, WPARAM};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, IPersistFile, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::Registry::{
    RegDeleteKeyValueW, RegDeleteTreeW, RegGetValueW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_DWORD,
    REG_EXPAND_SZ, REG_SZ, REG_VALUE_TYPE, RRF_NOEXPAND, RRF_RT_REG_EXPAND_SZ, RRF_RT_REG_SZ,
};
use windows::Win32::System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE};
use windows::Win32::UI::Shell::{IShellLinkW, ShellLink};
use windows::Win32::UI::WindowsAndMessaging::{
    MessageBoxW, SendMessageTimeoutW, HWND_BROADCAST, IDYES, MB_ICONERROR, MB_ICONINFORMATION,
    MB_ICONQUESTION, MB_OK, MB_YESNO, MESSAGEBOX_STYLE, SMTO_ABORTIFHUNG, WM_SETTINGCHANGE,
};

use crate::VERSION;

const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Blip";
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const ENV_KEY: &str = "Environment";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn env_dir(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).map(PathBuf::from)
}

pub fn install_dir() -> Option<PathBuf> {
    env_dir("LOCALAPPDATA").map(|d| d.join("Programs").join("Blip"))
}

pub fn installed_exe() -> Option<PathBuf> {
    install_dir().map(|d| d.join("Blip.exe"))
}

fn start_menu_link() -> Option<PathBuf> {
    env_dir("APPDATA").map(|d| d.join(r"Microsoft\Windows\Start Menu\Programs\Blip.lnk"))
}

/// Marker for "the user chose to keep running the download" (so the offer doesn't nag).
fn portable_marker() -> PathBuf {
    blip_core::paths::data_dir().join("portable-chosen")
}

fn same_file(a: &Path, b: &Path) -> bool {
    let norm = |p: &Path| {
        p.canonicalize()
            .unwrap_or_else(|_| p.to_path_buf())
            .to_string_lossy()
            .to_lowercase()
    };
    norm(a) == norm(b)
}

/// Whether this process is the installed copy.
pub fn is_installed_copy() -> bool {
    match (std::env::current_exe(), installed_exe()) {
        (Ok(me), Some(inst)) => same_file(&me, &inst),
        _ => false,
    }
}

// --- registry -----------------------------------------------------------------------------

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn set_string_typed(key: &str, name: &str, value: &str, kind: REG_VALUE_TYPE) {
    let v = wide(value);
    // SAFETY: HKCU write of a NUL-terminated UTF-16 buffer.
    unsafe {
        let _ = RegSetKeyValueW(
            HKEY_CURRENT_USER,
            &HSTRING::from(key),
            &HSTRING::from(name),
            kind.0,
            Some(v.as_ptr() as _),
            (v.len() * 2) as u32,
        );
    }
}

fn set_string(key: &str, name: &str, value: &str) {
    set_string_typed(key, name, value, REG_SZ);
}

fn set_dword(key: &str, name: &str, value: u32) {
    // SAFETY: HKCU write of a u32.
    unsafe {
        let _ = RegSetKeyValueW(
            HKEY_CURRENT_USER,
            &HSTRING::from(key),
            &HSTRING::from(name),
            REG_DWORD.0,
            Some(&value as *const u32 as _),
            4,
        );
    }
}

/// A string value without expanding %VARIABLES%, and whether it was REG_EXPAND_SZ.
fn get_string_raw(key: &str, name: &str) -> Option<(String, bool)> {
    let (k, n) = (HSTRING::from(key), HSTRING::from(name));
    let flags = RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND;
    let mut size = 0u32;
    let mut kind = REG_VALUE_TYPE::default();
    // SAFETY: size query, then a buffer of that size.
    unsafe {
        if RegGetValueW(
            HKEY_CURRENT_USER,
            &k,
            &n,
            flags,
            Some(&mut kind),
            None,
            Some(&mut size),
        )
        .0 != 0
        {
            return None;
        }
        let mut buf = vec![0u16; (size as usize).div_ceil(2) + 1];
        if RegGetValueW(
            HKEY_CURRENT_USER,
            &k,
            &n,
            flags,
            Some(&mut kind),
            Some(buf.as_mut_ptr() as _),
            Some(&mut size),
        )
        .0 != 0
        {
            return None;
        }
        let end = buf.iter().position(|c| *c == 0).unwrap_or(buf.len());
        Some((String::from_utf16_lossy(&buf[..end]), kind == REG_EXPAND_SZ))
    }
}

fn delete_value(key: &str, name: &str) {
    // SAFETY: HKCU delete of one value.
    unsafe {
        let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, &HSTRING::from(key), &HSTRING::from(name));
    }
}

fn installed_version() -> Option<String> {
    get_string_raw(UNINSTALL_KEY, "DisplayVersion").map(|v| v.0)
}

/// Adds (or removes) the install folder in the user's PATH, keeping the value's type and
/// every other entry exactly as it was, then tells running apps the environment changed.
fn set_on_path(dir: &Path, present: bool) {
    let dir_s = dir.display().to_string();
    let (current, expand) = get_string_raw(ENV_KEY, "Path").unwrap_or_default();
    let next = path_with(&current, &dir_s, present);
    if next == current {
        return;
    }
    if next.is_empty() {
        delete_value(ENV_KEY, "Path");
    } else {
        // A user PATH that didn't exist yet is written as REG_EXPAND_SZ, as Windows does.
        let kind = if expand || current.is_empty() {
            REG_EXPAND_SZ
        } else {
            REG_SZ
        };
        set_string_typed(ENV_KEY, "Path", &next, kind);
    }
    let env = wide("Environment");
    // SAFETY: broadcast with a 2 s cap so a hung window can't stall the installer.
    unsafe {
        let _ = SendMessageTimeoutW(
            HWND_BROADCAST,
            WM_SETTINGCHANGE,
            WPARAM(0),
            LPARAM(env.as_ptr() as isize),
            SMTO_ABORTIFHUNG,
            2000,
            None,
        );
    }
}

/// `current` with `dir` present once (appended) or removed (every case-insensitive match).
pub fn path_with(current: &str, dir: &str, present: bool) -> String {
    let same = |e: &str| {
        e.trim()
            .trim_end_matches('\\')
            .eq_ignore_ascii_case(dir.trim_end_matches('\\'))
    };
    let mut parts: Vec<&str> = current.split(';').filter(|e| !e.is_empty()).collect();
    let had = parts.iter().any(|e| same(e));
    if present {
        if had {
            return current.to_string();
        }
        parts.push(dir);
    } else {
        if !had {
            return current.to_string();
        }
        parts.retain(|e| !same(e));
    }
    parts.join(";")
}

// --- versions ------------------------------------------------------------------------------

/// Orders "2.1.0" > "2.1.0-preview.2" > "2.1.0-preview.1" > "2.0.12".
pub fn compare_versions(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let split = |v: &str| {
        let (main, pre) = match v.trim_start_matches('v').split_once('-') {
            Some((m, p)) => (m.to_string(), Some(p.to_string())),
            None => (v.trim_start_matches('v').to_string(), None),
        };
        let nums: Vec<u64> = main.split('.').map(|x| x.parse().unwrap_or(0)).collect();
        (nums, pre)
    };
    let (an, ap) = split(a);
    let (bn, bp) = split(b);
    for i in 0..an.len().max(bn.len()) {
        let o = an.get(i).unwrap_or(&0).cmp(bn.get(i).unwrap_or(&0));
        if o != Ordering::Equal {
            return o;
        }
    }
    match (ap, bp) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(x), Some(y)) => {
            let parts =
                |s: &str| -> Vec<u64> { s.split(['.', '-']).filter_map(|p| p.parse().ok()).collect() };
            parts(&x).cmp(&parts(&y)).then(x.cmp(&y))
        }
    }
}

// --- install / uninstall -------------------------------------------------------------------

fn message(title: &str, text: &str, style: MESSAGEBOX_STYLE) -> bool {
    // SAFETY: modal message box with owned strings.
    unsafe { MessageBoxW(None, &HSTRING::from(text), &HSTRING::from(title), style) == IDYES }
}

/// Asks a running Blip to quit and waits until it has (it releases Keep Awake on the way out).
pub fn close_running() {
    crate::winsys::close_running();
}

/// Waits (up to 10 s) for a previous Blip process to exit before this one starts.
pub fn wait_for_pid(pid: u32) {
    // SAFETY: a synchronize-only handle, closed below.
    unsafe {
        if let Ok(h) = OpenProcess(PROCESS_SYNCHRONIZE, false, pid) {
            WaitForSingleObject(h, 10_000);
            let _ = CloseHandle(h);
        }
    }
}

pub fn launch(exe: &Path, args: &[&str]) {
    let _ = Command::new(exe).args(args).spawn();
}

fn create_shortcut(exe: &Path, link: &Path) -> windows::core::Result<()> {
    // SAFETY: COM on this thread (initialised here if it wasn't already).
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let shell: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
        let exe_h = HSTRING::from(exe.as_os_str());
        shell.SetPath(&exe_h)?;
        shell.SetArguments(w!("--show"))?;
        shell.SetIconLocation(&exe_h, 0)?;
        shell.SetDescription(w!("Blip: a featherlight system monitor"))?;
        if let Some(dir) = exe.parent() {
            shell.SetWorkingDirectory(&HSTRING::from(dir.as_os_str()))?;
        }
        let file: IPersistFile = shell.cast()?;
        file.Save(&HSTRING::from(link.as_os_str()), true)?;
    }
    Ok(())
}

/// Copies with retries: an exe that just quit can hold its file for a moment.
fn copy_retrying(from: &Path, to: &Path) -> Result<(), String> {
    let mut last = None;
    for _ in 0..20 {
        match std::fs::copy(from, to) {
            Ok(_) => return Ok(()),
            Err(e) => {
                last = Some(e);
                std::thread::sleep(Duration::from_millis(250));
            }
        }
    }
    Err(format!(
        "{}: {}",
        to.display(),
        last.map(|e| e.to_string()).unwrap_or_default()
    ))
}

/// Copies this exe (and `blip-cli.exe` beside it) into place and registers it. A running
/// installed copy must already be closed.
pub fn install() -> Result<PathBuf, String> {
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    let dir = install_dir().ok_or("LOCALAPPDATA isn't set")?;
    let exe = dir.join("Blip.exe");
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    if !same_file(&me, &exe) {
        copy_retrying(&me, &exe)?;
        if let Some(cli) = me.parent().map(|d| d.join("blip-cli.exe")).filter(|c| c.exists()) {
            copy_retrying(&cli, &dir.join("blip-cli.exe"))?;
        }
    }
    if let Some(link) = start_menu_link() {
        let _ = create_shortcut(&exe, &link);
    }
    let quoted = format!("\"{}\"", exe.display());
    set_string(UNINSTALL_KEY, "DisplayName", "Blip");
    set_string(UNINSTALL_KEY, "DisplayVersion", VERSION);
    set_string(UNINSTALL_KEY, "Publisher", "Blaine Miller");
    set_string(UNINSTALL_KEY, "DisplayIcon", &format!("{quoted},0"));
    set_string(UNINSTALL_KEY, "InstallLocation", &dir.display().to_string());
    set_string(UNINSTALL_KEY, "UninstallString", &format!("{quoted} --uninstall"));
    set_string(
        UNINSTALL_KEY,
        "QuietUninstallString",
        &format!("{quoted} --uninstall --quiet"),
    );
    set_string(UNINSTALL_KEY, "URLInfoAbout", "https://github.com/blaineam/blip");
    set_dword(UNINSTALL_KEY, "NoModify", 1);
    set_dword(UNINSTALL_KEY, "NoRepair", 1);
    let size_kb = std::fs::read_dir(&dir)
        .map(|d| {
            d.flatten()
                .filter_map(|e| e.metadata().ok())
                .map(|m| m.len())
                .sum::<u64>()
                / 1024
        })
        .unwrap_or(0) as u32;
    set_dword(UNINSTALL_KEY, "EstimatedSize", size_kb);
    // Start at login, from the installed copy (the same value Settings › Launch at login uses).
    set_string(RUN_KEY, "Blip", &format!("{quoted} --background"));
    set_on_path(&dir, true);
    let _ = std::fs::remove_file(portable_marker());
    Ok(exe)
}

fn report_error(e: &str) {
    message(
        &tf("Blip couldn't be installed: %@", &[&e]),
        "",
        MB_OK | MB_ICONERROR,
    );
}

/// At launch from anywhere but the installed copy: offer to install or update, or open the
/// installed copy. Returns true when this process should exit (another copy takes over).
pub fn offer() -> bool {
    if let Some(exe) = installed_exe().filter(|p| p.exists()) {
        let version = installed_version().unwrap_or_else(|| "0".into());
        if compare_versions(VERSION, &version) == std::cmp::Ordering::Greater {
            let text = tf(
                "The installed Blip is %@. Update it to %@?",
                &[&version, &VERSION],
            );
            if !message(&t("Update Blip?"), &text, MB_YESNO | MB_ICONQUESTION) {
                return false;
            }
            crate::winsys::close_running();
            match install() {
                Ok(exe) => launch(&exe, &[]),
                Err(e) => {
                    report_error(&e);
                    return false;
                }
            }
        } else {
            // Same or newer version already installed: use it.
            launch(&exe, &["--show"]);
        }
        return true;
    }
    if portable_marker().exists() {
        return false;
    }
    let text = format!(
        "{}\n\n{}",
        t("Blip can install itself for your user: it is copied to your user folder, added to the Start menu and to Settings › Apps, and starts at login. No administrator rights are needed."),
        t("Choose No to keep running it from where it is.")
    );
    if !message(&t("Install Blip?"), &text, MB_YESNO | MB_ICONQUESTION) {
        let _ = std::fs::create_dir_all(blip_core::paths::data_dir());
        let _ = std::fs::write(portable_marker(), b"1");
        return false;
    }
    match install() {
        Ok(exe) => {
            launch(&exe, &["--show"]);
            true
        }
        Err(e) => {
            report_error(&e);
            false
        }
    }
}

/// "Install Blip…" in Settings of a portable copy: install, then hand over to the installed
/// copy once this process has quit. Returns true if the caller should quit.
pub fn install_from_settings() -> bool {
    match install() {
        Ok(exe) => {
            let pid = std::process::id().to_string();
            launch(&exe, &["--wait", &pid, "--show"]);
            true
        }
        Err(e) => {
            report_error(&e);
            false
        }
    }
}

/// `--uninstall`: removes the installed copy, its shortcut, login entry, PATH entry, Settings ›
/// Apps entry and its data folder. The exe can't delete itself while running, so a hidden `cmd`
/// removes the folder a moment after this process exits.
pub fn uninstall(quiet: bool) {
    if !quiet
        && !message(
            &t("Uninstall Blip?"),
            &t("This removes Blip, its Start menu entry and its settings."),
            MB_YESNO | MB_ICONQUESTION,
        )
    {
        return;
    }
    // Settings › Apps starts a second copy with --uninstall; quit the one in the tray (which
    // also undoes any Keep Awake lid change).
    crate::winsys::close_running();
    // SAFETY: deleting our own per-user registry tree.
    unsafe {
        let _ = RegDeleteTreeW(HKEY_CURRENT_USER, &HSTRING::from(UNINSTALL_KEY));
    }
    delete_value(RUN_KEY, "Blip");
    if let Some(link) = start_menu_link() {
        let _ = std::fs::remove_file(link);
    }
    let _ = std::fs::remove_dir_all(blip_core::paths::data_dir());
    if let Some(dir) = install_dir() {
        set_on_path(&dir, false);
        if is_installed_copy() {
            let script = format!("ping 127.0.0.1 -n 3 >nul & rmdir /s /q \"{}\"", dir.display());
            let _ = Command::new("cmd.exe")
                .args(["/c", &script])
                .creation_flags(CREATE_NO_WINDOW)
                .spawn();
        } else {
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
    if !quiet {
        message("Blip", &t("Blip was uninstalled."), MB_OK | MB_ICONINFORMATION);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cmp::Ordering::*;

    #[test]
    fn versions() {
        assert_eq!(compare_versions("2.1.0", "2.1.0-preview.2"), Greater);
        assert_eq!(compare_versions("2.1.0-preview.2", "2.1.0-preview.10"), Less);
        assert_eq!(compare_versions("2.1.0-preview.1", "2.0.12"), Greater);
        assert_eq!(compare_versions("2.1.0", "2.1"), Equal);
        assert_eq!(compare_versions("0", "2.1.0"), Less);
    }

    #[test]
    fn user_path_edits() {
        let dir = r"C:\Users\a\AppData\Local\Programs\Blip";
        assert_eq!(path_with("", dir, true), dir);
        let p = r"%USERPROFILE%\bin;C:\Tools";
        let added = path_with(p, dir, true);
        assert_eq!(added, format!("{p};{dir}"));
        assert_eq!(path_with(&added, dir, true), added, "no duplicates");
        assert_eq!(path_with(&added, &dir.to_uppercase(), false), p);
        assert_eq!(path_with(p, dir, false), p, "untouched when absent");
    }
}
