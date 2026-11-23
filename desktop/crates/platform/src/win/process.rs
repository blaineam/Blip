//! Ending processes. Windows only lets a standard user terminate processes they own, which is
//! exactly the Mac's rule — so the OS enforces it, and a system process fails with
//! "Access is denied".

use windows::Win32::Foundation::CloseHandle;
use windows::Win32::System::Threading::{OpenProcess, TerminateProcess, PROCESS_TERMINATE};

pub fn kill(pid: u32) -> Result<(), String> {
    if pid == 0 || pid == 4 || pid == std::process::id() {
        return Err("Blip won't end that process.".into());
    }
    // SAFETY: handle closed below.
    unsafe {
        let h = OpenProcess(PROCESS_TERMINATE, false, pid).map_err(|e| e.message())?;
        let r = TerminateProcess(h, 1).map_err(|e| e.message());
        let _ = CloseHandle(h);
        r
    }
}
