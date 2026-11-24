//! Device handles + IOCTLs shared by the battery and storage readers.

use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAGS_AND_ATTRIBUTES, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows::Win32::System::IO::DeviceIoControl;

pub const GENERIC_READ: u32 = 0x8000_0000;
pub const GENERIC_WRITE: u32 = 0x4000_0000;

pub struct Device(pub HANDLE);

impl Device {
    /// Opens a device path. `access` 0 = query-only (no read/write rights), which is all many
    /// storage IOCTLs need and what standard users are allowed on physical drives.
    pub fn open(path: &str, access: u32) -> Option<Self> {
        let w: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
        // SAFETY: NUL-terminated path; handle is owned by the returned Device.
        let h = unsafe {
            CreateFileW(
                PCWSTR(w.as_ptr()),
                access,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                None,
                OPEN_EXISTING,
                FILE_FLAGS_AND_ATTRIBUTES(0),
                None,
            )
        }
        .ok()?;
        Some(Self(h))
    }

    /// IOCTL with typed in/out buffers; returns bytes written into `out`.
    pub fn ioctl<I, O>(&self, code: u32, input: Option<&I>, out: &mut O) -> Option<u32> {
        self.ioctl_raw(
            code,
            input.map(|i| {
                (
                    i as *const I as *const core::ffi::c_void,
                    std::mem::size_of::<I>() as u32,
                )
            }),
            (
                out as *mut O as *mut core::ffi::c_void,
                std::mem::size_of::<O>() as u32,
            ),
        )
    }

    pub fn ioctl_raw(
        &self,
        code: u32,
        input: Option<(*const core::ffi::c_void, u32)>,
        out: (*mut core::ffi::c_void, u32),
    ) -> Option<u32> {
        let mut returned = 0u32;
        // SAFETY: the caller's buffers are valid for the sizes given.
        unsafe {
            DeviceIoControl(
                self.0,
                code,
                input.map(|i| i.0),
                input.map_or(0, |i| i.1),
                Some(out.0),
                out.1,
                Some(&mut returned),
                None,
            )
        }
        .ok()?;
        Some(returned)
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        // SAFETY: we own the handle.
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}
