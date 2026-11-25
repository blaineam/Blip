//! A small diagnostic log (`blip.log` in the data folder). The Windows tray app has no console,
//! so without it a failed start leaves no trace. Local only; it never leaves the machine.

use std::io::Write;

const MAX_BYTES: u64 = 256 * 1024;

/// Appends one timestamped line. Never fails and never panics; starts over once the file is large.
pub fn log(message: &str) {
    let path = crate::paths::log_file();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let big = std::fs::metadata(&path).is_ok_and(|m| m.len() > MAX_BYTES);
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(!big)
        .write(true)
        .truncate(big)
        .open(&path);
    if let Ok(mut f) = file {
        let _ = writeln!(
            f,
            "{} [{}] {message}",
            crate::model::now_unix(),
            std::process::id()
        );
    }
}
