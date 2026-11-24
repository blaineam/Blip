//! Keep Awake. Windows: a power request (the API `powercfg /requests` lists), the lid-close
//! action set to "Do nothing" on the active plan for the duration (a per-user power-plan write —
//! no admin on default policy; restored on release, on quit, and on the next launch if Blip
//! died mid-session), and an idle mouse jiggle. Linux: a logind inhibitor plus the desktop's
//! idle inhibit (`crate::linux::power`). macOS dev hosts: `caffeinate`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AwakeOptions {
    pub keep_display_on: bool,
    pub ignore_lid: bool,
    pub jiggle: bool,
}

#[derive(Default)]
pub struct KeepAwake {
    active: Option<AwakeOptions>,
    #[cfg(windows)]
    request: Option<crate::win::power::PowerRequest>,
    #[cfg(windows)]
    lid: Option<crate::win::power::LidOverride>,
    #[cfg(target_os = "linux")]
    inhibitor: Option<crate::linux::power::Inhibitor>,
    #[cfg(target_os = "macos")]
    child: Option<std::process::Child>,
    jiggler: Option<Arc<AtomicBool>>,
    pub last_error: Option<String>,
}

impl KeepAwake {
    pub fn new() -> Self {
        #[cfg(windows)]
        crate::win::power::LidOverride::restore_stale();
        Self::default()
    }

    pub fn active(&self) -> Option<AwakeOptions> {
        self.active
    }

    /// Lid-closed support exists on this machine (it has a lid / the plan exposes the setting).
    pub fn lid_supported() -> bool {
        #[cfg(windows)]
        {
            crate::win::power::LidOverride::supported()
        }
        #[cfg(target_os = "linux")]
        {
            crate::linux::power::has_lid()
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            false
        }
    }

    /// The idle mouse jiggle works here (everywhere but Wayland sessions on Linux).
    pub fn jiggle_supported() -> bool {
        #[cfg(target_os = "linux")]
        {
            crate::linux::power::jiggle_supported()
        }
        #[cfg(not(target_os = "linux"))]
        {
            cfg!(windows)
        }
    }

    pub fn engage(&mut self, opts: AwakeOptions) {
        if self.active == Some(opts) {
            return;
        }
        self.release();
        self.last_error = None;
        #[cfg(windows)]
        {
            match crate::win::power::PowerRequest::new(opts.keep_display_on) {
                Ok(r) => self.request = Some(r),
                Err(e) => self.last_error = Some(e),
            }
            if opts.ignore_lid {
                match crate::win::power::LidOverride::engage() {
                    Ok(l) => self.lid = Some(l),
                    Err(e) => self.last_error = Some(e),
                }
            }
        }
        #[cfg(target_os = "macos")]
        {
            let flags = if opts.keep_display_on { "-di" } else { "-i" };
            self.child = std::process::Command::new("caffeinate").arg(flags).spawn().ok();
        }
        #[cfg(target_os = "linux")]
        match crate::linux::power::Inhibitor::engage(opts.keep_display_on, opts.ignore_lid) {
            Ok(i) => self.inhibitor = Some(i),
            Err(e) => self.last_error = Some(e),
        }
        if opts.jiggle {
            let stop = Arc::new(AtomicBool::new(false));
            let s2 = stop.clone();
            std::thread::Builder::new()
                .name("blip-jiggle".into())
                .spawn(move || {
                    while !s2.load(Ordering::Relaxed) {
                        for _ in 0..30 {
                            if s2.load(Ordering::Relaxed) {
                                return;
                            }
                            std::thread::sleep(std::time::Duration::from_secs(1));
                        }
                        #[cfg(windows)]
                        crate::win::power::jiggle_if_idle(60);
                        #[cfg(target_os = "linux")]
                        crate::linux::power::jiggle_if_idle(60);
                    }
                })
                .ok();
            self.jiggler = Some(stop);
        }
        self.active = Some(opts);
    }

    pub fn release(&mut self) {
        #[cfg(windows)]
        {
            self.request = None;
            self.lid = None;
        }
        #[cfg(target_os = "linux")]
        {
            self.inhibitor = None;
        }
        #[cfg(target_os = "macos")]
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        if let Some(j) = self.jiggler.take() {
            j.store(true, Ordering::Relaxed);
        }
        self.active = None;
    }
}

impl Drop for KeepAwake {
    fn drop(&mut self) {
        self.release();
    }
}
