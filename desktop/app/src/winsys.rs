//! Small Windows integrations the app shell needs: single instance (a second launch opens the
//! running Blip), the monitor work area around the tray, and the taskbar's light/dark mode.

#[derive(Debug, Clone, Copy)]
pub struct WorkArea {
    /// Physical pixels.
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
    /// Monitor scale (1.0 = 96 dpi).
    pub scale: f32,
}

#[cfg(windows)]
mod imp {
    use windows::core::w;
    use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, POINT};
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use windows::Win32::System::Registry::HKEY_CURRENT_USER;
    use windows::Win32::System::Threading::*;
    use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};

    use super::WorkArea;

    /// Returns false when another Blip is already running (after asking it to show itself).
    pub fn claim_single_instance(on_show: impl Fn() + Send + 'static) -> bool {
        // SAFETY: named kernel objects in the session namespace; handles live for the process.
        unsafe {
            let _mutex = CreateMutexW(None, true, w!("Local\\BlipDesktop.Instance"));
            if GetLastError() == ERROR_ALREADY_EXISTS {
                if let Ok(ev) = OpenEventW(EVENT_MODIFY_STATE, false, w!("Local\\BlipDesktop.Show")) {
                    let _ = SetEvent(ev);
                }
                return false;
            }
            if let Ok(ev) = CreateEventW(None, false, false, w!("Local\\BlipDesktop.Show")) {
                let raw = ev.0 as isize;
                std::thread::spawn(move || loop {
                    let h = windows::Win32::Foundation::HANDLE(raw as _);
                    if WaitForSingleObject(h, INFINITE).0 == 0 {
                        on_show();
                    } else {
                        break;
                    }
                });
            }
            std::mem::forget(_mutex);
        }
        true
    }

    pub fn work_area_at(x: f32, y: f32) -> Option<WorkArea> {
        // SAFETY: plain monitor queries.
        unsafe {
            let mon = MonitorFromPoint(
                POINT {
                    x: x as i32,
                    y: y as i32,
                },
                MONITOR_DEFAULTTONEAREST,
            );
            let mut mi = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            if !GetMonitorInfoW(mon, &mut mi).as_bool() {
                return None;
            }
            let (mut dx, mut dy) = (96u32, 96u32);
            let _ = GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &mut dx, &mut dy);
            let r = mi.rcWork;
            Some(WorkArea {
                left: r.left as f32,
                top: r.top as f32,
                right: r.right as f32,
                bottom: r.bottom as f32,
                scale: dx as f32 / 96.0,
            })
        }
    }

    pub fn light_taskbar() -> bool {
        blip_platform_reg_dword(
            "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
            "SystemUsesLightTheme",
        ) == Some(1)
    }

    fn blip_platform_reg_dword(key: &str, value: &str) -> Option<u32> {
        use windows::core::HSTRING;
        use windows::Win32::System::Registry::{RegGetValueW, RRF_RT_REG_DWORD};
        let (k, v) = (HSTRING::from(key), HSTRING::from(value));
        let mut data = 0u32;
        let mut size = 4u32;
        // SAFETY: DWORD out-param.
        let rc = unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                &k,
                &v,
                RRF_RT_REG_DWORD,
                None,
                Some(&mut data as *mut u32 as _),
                Some(&mut size),
            )
        };
        (rc.0 == 0).then_some(data)
    }
}

#[cfg(not(windows))]
mod imp {
    use super::WorkArea;
    pub fn claim_single_instance(_on_show: impl Fn() + Send + 'static) -> bool {
        true
    }
    pub fn work_area_at(_x: f32, _y: f32) -> Option<WorkArea> {
        None
    }
    pub fn light_taskbar() -> bool {
        false
    }
}

pub use imp::*;
