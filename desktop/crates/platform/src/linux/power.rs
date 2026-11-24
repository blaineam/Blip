//! Keep Awake on Linux, all as the signed-in user:
//! - systemd-logind `Inhibit("sleep[:handle-lid-switch]", …, "block")`: logind holds the lock
//!   for as long as Blip holds the returned file descriptor, so a crash can't leave the
//!   machine sleepless (unlike Windows, nothing has to be restored on the next launch).
//!   Active local sessions may take both locks by default polkit policy.
//! - The desktop's own idle/suspend timers: the XDG desktop portal's `Inhibit` (GNOME, KDE,
//!   SteamOS desktop mode), else `org.freedesktop.ScreenSaver.Inhibit` (Xfce, LXQt, older KDE).
//! - Mouse jiggle: XTest on X11 sessions. Wayland gives clients no way to move the pointer, so
//!   the option is hidden there.

use std::collections::HashMap;
use std::os::fd::OwnedFd;

use zbus::zvariant::{OwnedObjectPath, Value};

use super::bus;

pub struct Inhibitor {
    sleep_fd: Option<OwnedFd>,
    portal_request: Option<String>,
    screensaver_cookie: Option<u32>,
}

impl Inhibitor {
    pub fn engage(keep_display_on: bool, ignore_lid: bool) -> Result<Self, String> {
        let mut me = Self {
            sleep_fd: None,
            portal_request: None,
            screensaver_cookie: None,
        };
        let mut what = String::from("sleep");
        if ignore_lid {
            what.push_str(":handle-lid-switch");
        }
        if keep_display_on {
            what.push_str(":idle");
        }
        let logind_err = match bus::system().and_then(|c| {
            bus::proxy(
                c,
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
            )
        }) {
            Some(p) => match p.call::<_, _, zbus::zvariant::OwnedFd>(
                "Inhibit",
                &(what.as_str(), "Blip", "Keep Awake", "block"),
            ) {
                Ok(fd) => {
                    me.sleep_fd = Some(fd.into());
                    None
                }
                Err(e) => Some(e.to_string()),
            },
            None => Some("systemd-logind isn't available.".to_string()),
        };

        // Portal flags: 4 = suspend, 8 = idle (screen blanking / screensaver).
        let flags: u32 = if keep_display_on { 4 | 8 } else { 4 };
        if let Some(c) = bus::session() {
            if let Some(p) = bus::proxy(
                c,
                "org.freedesktop.portal.Desktop",
                "/org/freedesktop/portal/desktop",
                "org.freedesktop.portal.Inhibit",
            ) {
                let opts: HashMap<&str, Value> = HashMap::from([("reason", Value::from("Keep Awake"))]);
                if let Ok(h) = p.call::<_, _, OwnedObjectPath>("Inhibit", &("", flags, opts)) {
                    me.portal_request = Some(bus::path_str(&h));
                }
            }
            if me.portal_request.is_none() && keep_display_on {
                for path in ["/org/freedesktop/ScreenSaver", "/ScreenSaver"] {
                    if let Some(p) = bus::proxy(
                        c,
                        "org.freedesktop.ScreenSaver",
                        path,
                        "org.freedesktop.ScreenSaver",
                    ) {
                        if let Ok(cookie) = p.call::<_, _, u32>("Inhibit", &("Blip", "Keep Awake")) {
                            me.screensaver_cookie = Some(cookie);
                            break;
                        }
                    }
                }
            }
        }
        if me.sleep_fd.is_none() && me.portal_request.is_none() && me.screensaver_cookie.is_none() {
            return Err(logind_err.unwrap_or_else(|| "No sleep inhibitor is available.".into()));
        }
        Ok(me)
    }
}

impl Drop for Inhibitor {
    fn drop(&mut self) {
        self.sleep_fd = None; // closing the fd releases logind's lock
        if let Some(c) = bus::session() {
            if let Some(h) = self.portal_request.take() {
                if let Some(p) = bus::proxy(
                    c,
                    "org.freedesktop.portal.Desktop",
                    &h,
                    "org.freedesktop.portal.Request",
                ) {
                    let _ = p.call::<_, _, ()>("Close", &());
                }
            }
            if let Some(cookie) = self.screensaver_cookie.take() {
                for path in ["/org/freedesktop/ScreenSaver", "/ScreenSaver"] {
                    if let Some(p) = bus::proxy(
                        c,
                        "org.freedesktop.ScreenSaver",
                        path,
                        "org.freedesktop.ScreenSaver",
                    ) {
                        if p.call::<_, _, ()>("UnInhibit", &(cookie,)).is_ok() {
                            break;
                        }
                    }
                }
            }
        }
    }
}

/// A laptop lid the kernel reports (ACPI button or a lid switch input device).
pub fn has_lid() -> bool {
    std::fs::read_dir("/proc/acpi/button/lid")
        .map(|mut d| d.next().is_some())
        .unwrap_or(false)
        || std::fs::read_dir("/sys/class/input").is_ok_and(|d| {
            d.flatten().any(|e| {
                super::procfs::read_trim(e.path().join("name"))
                    .is_some_and(|n| n.to_ascii_lowercase().contains("lid switch"))
            })
        })
}

/// X11 (or XWayland-only desktops reporting x11) — where XTest can move the pointer.
pub fn jiggle_supported() -> bool {
    std::env::var_os("DISPLAY").is_some()
        && std::env::var("XDG_SESSION_TYPE")
            .map(|t| t != "wayland")
            .unwrap_or(true)
}

/// Nudges the pointer one pixel and back if the user has been idle for `idle_secs`.
pub fn jiggle_if_idle(idle_secs: u32) {
    use x11rb::connection::Connection as _;
    use x11rb::protocol::screensaver::ConnectionExt as _;
    use x11rb::protocol::xproto::MOTION_NOTIFY_EVENT;
    use x11rb::protocol::xtest::ConnectionExt as _;
    if !jiggle_supported() {
        return;
    }
    let Ok((conn, screen)) = x11rb::connect(None) else {
        return;
    };
    let root = conn.setup().roots[screen].root;
    let idle_ms = conn
        .screensaver_query_info(root)
        .ok()
        .and_then(|c| c.reply().ok())
        .map(|r| r.ms_since_user_input)
        .unwrap_or(0);
    if idle_ms < idle_secs * 1000 {
        return;
    }
    // detail 1 = relative motion.
    let _ = conn.xtest_fake_input(MOTION_NOTIFY_EVENT, 1, x11rb::CURRENT_TIME, x11rb::NONE, 1, 0, 0);
    let _ = conn.xtest_fake_input(MOTION_NOTIFY_EVENT, 1, x11rb::CURRENT_TIME, x11rb::NONE, -1, 0, 0);
    let _ = conn.flush();
}

/// The usable desktop area (`_NET_WORKAREA`: the screen minus panels/docks), in X11 pixels.
pub fn work_area() -> Option<[i32; 4]> {
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt as _};
    std::env::var_os("DISPLAY")?;
    let (conn, screen) = x11rb::connect(None).ok()?;
    let root = conn.setup().roots[screen].root;
    let atom = conn.intern_atom(true, b"_NET_WORKAREA").ok()?.reply().ok()?.atom;
    if atom == 0 {
        return None;
    }
    let r = conn
        .get_property(false, root, atom, AtomEnum::CARDINAL, 0, 4)
        .ok()?
        .reply()
        .ok()?;
    let v: Vec<u32> = r.value32()?.collect();
    (v.len() >= 4 && v[2] > 0 && v[3] > 0).then(|| [v[0] as i32, v[1] as i32, v[2] as i32, v[3] as i32])
}
