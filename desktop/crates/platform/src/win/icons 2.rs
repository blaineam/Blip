//! Process icons: the executable's small icon, rasterised to 16×16 RGBA for the process lists.

use windows::core::HSTRING;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Shell::ExtractIconExW;
use windows::Win32::UI::WindowsAndMessaging::{DestroyIcon, DrawIconEx, DI_NORMAL, HICON};

pub fn exe_icon(path: &str) -> Option<(u32, u32, Vec<u8>)> {
    const S: i32 = 16;
    let p = HSTRING::from(path);
    let mut small = HICON::default();
    // SAFETY: one small icon out-param; destroyed below.
    let n = unsafe { ExtractIconExW(&p, 0, None, Some(&mut small), 1) };
    if n == 0 || small.is_invalid() {
        return None;
    }
    let bmi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: S,
            biHeight: -S, // top-down
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut out = None;
    // SAFETY: memory DC + DIB section we own; pixels read before teardown.
    unsafe {
        let dc = CreateCompatibleDC(None);
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        if let Ok(bmp) = CreateDIBSection(Some(dc), &bmi, DIB_RGB_COLORS, &mut bits, None, 0) {
            let old = SelectObject(dc, bmp.into());
            if DrawIconEx(dc, 0, 0, small, S, S, 0, None, DI_NORMAL).is_ok() && !bits.is_null() {
                let px = std::slice::from_raw_parts(bits as *const u8, (S * S * 4) as usize);
                let has_alpha = px.chunks(4).any(|c| c[3] != 0);
                let rgba: Vec<u8> = px
                    .chunks(4)
                    .flat_map(|c| {
                        let a = if has_alpha {
                            c[3]
                        } else if c[0] | c[1] | c[2] != 0 {
                            255
                        } else {
                            0
                        };
                        [c[2], c[1], c[0], a]
                    })
                    .collect();
                out = Some((S as u32, S as u32, rgba));
            }
            SelectObject(dc, old);
            let _ = DeleteObject(bmp.into());
        }
        let _ = DeleteDC(dc);
        let _ = DestroyIcon(small);
    }
    out
}
