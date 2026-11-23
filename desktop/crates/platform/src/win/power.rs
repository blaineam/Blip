//! Keep Awake on Windows. A power request is the documented way to hold off sleep (visible in
//! `powercfg /requests`); lid-closed mode flips the active plan's "lid close action" to Do
//! nothing for the session — a per-user plan write that default policy allows standard users —
//! and records the original values on disk first, so a crash is undone at the next launch.

use windows::core::{GUID, PWSTR};
use windows::Win32::Foundation::{CloseHandle, LocalFree, HANDLE, HLOCAL};
use windows::Win32::System::Power::*;
use windows::Win32::System::SystemInformation::GetTickCount;
use windows::Win32::System::Threading::{
    POWER_REQUEST_CONTEXT_SIMPLE_STRING, REASON_CONTEXT, REASON_CONTEXT_0,
};
use windows::Win32::UI::Input::KeyboardAndMouse::*;

pub struct PowerRequest {
    handle: HANDLE,
    display: bool,
}

// The handle is a kernel object usable from any thread.
unsafe impl Send for PowerRequest {}

impl PowerRequest {
    pub fn new(keep_display_on: bool) -> Result<Self, String> {
        let mut reason: Vec<u16> = "Blip Keep Awake"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let ctx = REASON_CONTEXT {
            Version: 0,
            Flags: POWER_REQUEST_CONTEXT_SIMPLE_STRING,
            Reason: REASON_CONTEXT_0 {
                SimpleReasonString: PWSTR(reason.as_mut_ptr()),
            },
        };
        // SAFETY: context + string live across the call.
        let handle = unsafe { PowerCreateRequest(&ctx) }.map_err(|e| e.message())?;
        unsafe {
            PowerSetRequest(handle, PowerRequestSystemRequired).map_err(|e| e.message())?;
            if keep_display_on {
                PowerSetRequest(handle, PowerRequestDisplayRequired).map_err(|e| e.message())?;
            }
        }
        Ok(Self {
            handle,
            display: keep_display_on,
        })
    }
}

impl Drop for PowerRequest {
    fn drop(&mut self) {
        // SAFETY: our request handle.
        unsafe {
            let _ = PowerClearRequest(self.handle, PowerRequestSystemRequired);
            if self.display {
                let _ = PowerClearRequest(self.handle, PowerRequestDisplayRequired);
            }
            let _ = CloseHandle(self.handle);
        }
    }
}

const GUID_SYSTEM_BUTTON_SUBGROUP: GUID = GUID::from_u128(0x4f971e89_eebd_4455_a8de_9e59040e7347);
const GUID_LIDSWITCH_STATE_CHANGE: GUID = GUID::from_u128(0x5ca83367_6e45_459f_a27b_476b1d01c936);

fn restore_file() -> std::path::PathBuf {
    blip_core::paths::data_dir().join("lid-restore.txt")
}

fn active_scheme() -> Option<GUID> {
    let mut p: *mut GUID = std::ptr::null_mut();
    // SAFETY: out-pointer; freed with LocalFree.
    let rc = unsafe { PowerGetActiveScheme(None, &mut p) };
    if rc.0 != 0 || p.is_null() {
        return None;
    }
    let g = unsafe { *p };
    unsafe {
        LocalFree(Some(HLOCAL(p as _)));
    }
    Some(g)
}

fn read(scheme: &GUID) -> Option<(u32, u32)> {
    let (mut ac, mut dc) = (0u32, 0u32);
    // SAFETY: GUID pointers to locals/consts; out-params.
    unsafe {
        if PowerReadACValueIndex(
            None,
            Some(scheme),
            Some(&GUID_SYSTEM_BUTTON_SUBGROUP),
            Some(&GUID_LIDSWITCH_STATE_CHANGE),
            &mut ac,
        )
        .0 != 0
        {
            return None;
        }
        if PowerReadDCValueIndex(
            None,
            Some(scheme),
            Some(&GUID_SYSTEM_BUTTON_SUBGROUP),
            Some(&GUID_LIDSWITCH_STATE_CHANGE),
            &mut dc,
        ) != 0
        {
            return None;
        }
    }
    Some((ac, dc))
}

fn write(scheme: &GUID, ac: u32, dc: u32) -> Result<(), String> {
    // SAFETY: as above.
    unsafe {
        let a = PowerWriteACValueIndex(
            None,
            scheme,
            Some(&GUID_SYSTEM_BUTTON_SUBGROUP),
            Some(&GUID_LIDSWITCH_STATE_CHANGE),
            ac,
        );
        let d = PowerWriteDCValueIndex(
            None,
            scheme,
            Some(&GUID_SYSTEM_BUTTON_SUBGROUP),
            Some(&GUID_LIDSWITCH_STATE_CHANGE),
            dc,
        );
        if a.0 != 0 || d != 0 {
            return Err(
                "Windows didn't allow changing the lid action (your organization may manage power settings)."
                    .into(),
            );
        }
        let _ = PowerSetActiveScheme(None, Some(scheme));
    }
    Ok(())
}

pub struct LidOverride {
    scheme: GUID,
    ac: u32,
    dc: u32,
}

impl LidOverride {
    pub fn supported() -> bool {
        active_scheme().and_then(|s| read(&s)).is_some() && super::system::has_lid()
    }

    pub fn engage() -> Result<Self, String> {
        let scheme = active_scheme().ok_or("No active power plan.")?;
        let (ac, dc) = read(&scheme).ok_or("This PC has no lid setting.")?;
        let _ = blip_core::paths::write_atomic(
            &restore_file(),
            format!("{} {ac} {dc}", scheme.to_u128()).as_bytes(),
        );
        write(&scheme, 0, 0)?;
        Ok(Self { scheme, ac, dc })
    }

    /// Undo an override a previous Blip left behind (crash / power loss mid-session).
    pub fn restore_stale() {
        let path = restore_file();
        let Ok(text) = std::fs::read_to_string(&path) else {
            return;
        };
        let parts: Vec<&str> = text.split_whitespace().collect();
        if let [g, ac, dc] = parts[..] {
            if let (Ok(g), Ok(ac), Ok(dc)) = (g.parse::<u128>(), ac.parse(), dc.parse()) {
                let _ = write(&GUID::from_u128(g), ac, dc);
            }
        }
        let _ = std::fs::remove_file(path);
    }
}

impl Drop for LidOverride {
    fn drop(&mut self) {
        let _ = write(&self.scheme, self.ac, self.dc);
        let _ = std::fs::remove_file(restore_file());
    }
}

/// Nudges the pointer one pixel and back if the user has been idle for `idle_secs`, so chat
/// apps don't flip to "Away". The move is relative and net zero.
pub fn jiggle_if_idle(idle_secs: u32) {
    let mut lii = LASTINPUTINFO {
        cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
        dwTime: 0,
    };
    // SAFETY: out-param.
    if !unsafe { GetLastInputInfo(&mut lii) }.as_bool() {
        return;
    }
    let idle_ms = unsafe { GetTickCount() }.wrapping_sub(lii.dwTime);
    if idle_ms < idle_secs * 1000 {
        return;
    }
    let mv = |dx: i32| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy: 0,
                mouseData: 0,
                dwFlags: MOUSEEVENTF_MOVE,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    // SAFETY: two well-formed inputs.
    unsafe {
        SendInput(&[mv(1), mv(-1)], std::mem::size_of::<INPUT>() as i32);
    }
}
