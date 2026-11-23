//! Where Blip keeps its files: `%APPDATA%\Blip` on Windows, `$XDG_CONFIG_HOME/blip` (or
//! `~/.config/blip`) on Linux. Everything is per-user — Blip never writes outside the profile.

use std::path::{Path, PathBuf};

pub fn data_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("BLIP_DATA_DIR") {
        return PathBuf::from(dir);
    }
    #[cfg(windows)]
    {
        if let Ok(appdata) = std::env::var("APPDATA") {
            return PathBuf::from(appdata).join("Blip");
        }
    }
    #[cfg(target_os = "macos")]
    {
        if let Ok(home) = std::env::var("HOME") {
            // Dev hosts only: kept apart from the real Mac app's container.
            return PathBuf::from(home).join("Library/Application Support/Blip Desktop");
        }
    }
    if let Ok(x) = std::env::var("XDG_CONFIG_HOME") {
        if !x.is_empty() {
            return PathBuf::from(x).join("blip");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".config/blip");
    }
    std::env::temp_dir().join("blip")
}

pub fn settings_file() -> PathBuf {
    data_dir().join("settings.json")
}
pub fn bench_history_file() -> PathBuf {
    data_dir().join("bench-history.json")
}
pub fn speed_history_file() -> PathBuf {
    data_dir().join("speed-history.json")
}
pub fn disk_history_file() -> PathBuf {
    data_dir().join("disk-speed-history.json")
}
pub fn geoip_file() -> PathBuf {
    data_dir().join("dbip-city-lite.mmdb")
}
pub fn log_file() -> PathBuf {
    data_dir().join("blip.log")
}

/// Write-then-rename so a crash mid-write never leaves a torn settings/history file.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)
}

pub fn load_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

pub fn save_json<T: serde::Serialize>(path: &Path, value: &T) {
    if let Ok(json) = serde_json::to_vec_pretty(value) {
        let _ = write_atomic(path, &json);
    }
}
