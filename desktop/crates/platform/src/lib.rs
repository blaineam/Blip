//! Where Blip's numbers come from. One `Sampler` per process, polled every couple of seconds;
//! it holds the deltas (CPU ticks, byte counters) between polls. Everything here runs as the
//! signed-in user — no admin, no driver, no service.
//!
//! The portable layer (`sysinfo`) covers CPU, memory, processes, volumes and interface counters
//! on every OS; Windows then layers native sources on top for what Task Manager shows and
//! `sysinfo` doesn't (user/kernel split, clock %, disk I/O, GPU engines, battery wear, NVMe
//! health, adapters, ICMP).

mod generic;
pub mod net;
#[cfg(windows)]
mod win;

use std::sync::Arc;

use blip_core::bench::GpuCompute;
use blip_core::model::Snapshot;

pub use generic::Sampler;

/// Round-trip time to `host` in ms (one ICMP echo, ~1 s timeout). Unprivileged everywhere:
/// IcmpSendEcho2 on Windows.
pub fn ping(host: &str) -> Option<f64> {
    net::ping(host, 1000)
}

/// The GPU leg of Blip Bench (Direct3D 11 compute on Windows).
pub fn gpu_compute() -> Option<Arc<dyn GpuCompute>> {
    #[cfg(windows)]
    {
        win::d3d::D3DCompute::new().map(|g| Arc::new(g) as Arc<dyn GpuCompute>)
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// Ends a process the user owns. System processes fail with "Access is denied".
pub fn kill_process(pid: u32) -> Result<(), String> {
    #[cfg(windows)]
    {
        win::process::kill(pid)
    }
    #[cfg(not(windows))]
    {
        let ok = std::process::Command::new("kill")
            .arg(pid.to_string())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            Ok(())
        } else {
            Err("Couldn't end that process.".into())
        }
    }
}

/// BCP-47 tag of the user's UI language ("de-DE").
pub fn ui_language() -> String {
    #[cfg(windows)]
    {
        win::system::ui_language()
    }
    #[cfg(not(windows))]
    {
        std::env::var("LC_ALL")
            .or_else(|_| std::env::var("LC_MESSAGES"))
            .or_else(|_| std::env::var("LANG"))
            .unwrap_or_default()
            .split('.')
            .next()
            .unwrap_or("")
            .to_string()
    }
}

/// Start Blip when the user signs in (HKCU Run key on Windows — no admin).
pub fn set_launch_at_login(enabled: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        win::system::set_launch_at_login(enabled)
    }
    #[cfg(not(windows))]
    {
        let _ = enabled;
        Err("Not supported on this platform yet.".into())
    }
}

pub fn launch_at_login() -> bool {
    #[cfg(windows)]
    {
        win::system::launch_at_login()
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Opens a URL or folder with the user's default handler.
pub fn open(target: &str) {
    #[cfg(windows)]
    win::system::shell_open(target);
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(target).spawn();
    #[cfg(all(unix, not(target_os = "macos")))]
    let _ = std::process::Command::new("xdg-open").arg(target).spawn();
}

/// Font files the UI should load from the OS (so the binary bundles none): the UI face, a
/// CJK fallback and the symbol font (Segoe Fluent Icons / MDL2 Assets on Windows).
#[derive(Debug, Default, Clone)]
pub struct SystemFonts {
    pub ui: Option<std::path::PathBuf>,
    pub ui_bold: Option<std::path::PathBuf>,
    pub mono: Option<std::path::PathBuf>,
    pub cjk: Vec<std::path::PathBuf>,
    pub symbols: Option<std::path::PathBuf>,
}

pub fn system_fonts() -> SystemFonts {
    let first = |c: &[&str]| c.iter().map(std::path::PathBuf::from).find(|p| p.exists());
    #[cfg(windows)]
    {
        let dir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into()) + "\\Fonts\\";
        let f = |names: &[&str]| {
            first(
                &names
                    .iter()
                    .map(|n| format!("{dir}{n}"))
                    .collect::<Vec<_>>()
                    .iter()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
            )
        };
        SystemFonts {
            ui: f(&["segoeui.ttf"]),
            ui_bold: f(&["seguisb.ttf", "segoeuib.ttf"]),
            mono: f(&["CascadiaMono.ttf", "consola.ttf"]),
            cjk: ["YuGothM.ttc", "meiryo.ttc", "malgun.ttf", "msyh.ttc", "msjh.ttc"]
                .iter()
                .map(|n| std::path::PathBuf::from(format!("{dir}{n}")))
                .filter(|p| p.exists())
                .collect(),
            symbols: f(&["SegoeIcons.ttf", "segmdl2.ttf"]),
        }
    }
    #[cfg(target_os = "macos")]
    {
        SystemFonts {
            ui: first(&[
                "/System/Library/Fonts/SFNS.ttf",
                "/System/Library/Fonts/Helvetica.ttc",
            ]),
            ui_bold: None,
            mono: first(&[
                "/System/Library/Fonts/SFNSMono.ttf",
                "/System/Library/Fonts/Menlo.ttc",
            ]),
            cjk: [
                "/System/Library/Fonts/Hiragino Sans GB.ttc",
                "/System/Library/Fonts/AppleSDGothicNeo.ttc",
            ]
            .iter()
            .map(std::path::PathBuf::from)
            .filter(|p| p.exists())
            .collect(),
            symbols: None,
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        SystemFonts {
            ui: first(&[
                "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                "/usr/share/fonts/dejavu/DejaVuSans.ttf",
                "/usr/share/fonts/noto/NotoSans-Regular.ttf",
            ]),
            ui_bold: None,
            mono: first(&[
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
            ]),
            cjk: [
                "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
            ]
            .iter()
            .map(std::path::PathBuf::from)
            .filter(|p| p.exists())
            .collect(),
            symbols: None,
        }
    }
}

/// Keep Awake: stop idle sleep (optionally keeping the display on), optionally ignore the lid
/// and jiggle the mouse, and undo every bit of it on `release()` / drop.
pub use power::{AwakeOptions, KeepAwake};

mod power;

/// A fresh, fully-populated snapshot (CLI one-shots): samples twice, `gap` apart, so rates exist.
pub fn snapshot_once(gap: std::time::Duration) -> Snapshot {
    let mut s = Sampler::new();
    s.sample();
    std::thread::sleep(gap);
    s.sample()
}

/// Small RGBA icon for a process's executable (16 px), if the OS will give us one.
pub fn exe_icon(path: &str) -> Option<(u32, u32, Vec<u8>)> {
    #[cfg(windows)]
    {
        win::icons::exe_icon(path)
    }
    #[cfg(not(windows))]
    {
        let _ = path;
        None
    }
}
