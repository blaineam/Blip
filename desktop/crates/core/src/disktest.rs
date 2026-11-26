//! Uncached sequential write/read + 4 KB random-read IOPS, ported from the Mac `DiskBenchmark`.
//! Windows opens the scratch file with FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH (the
//! F_NOCACHE equivalent — needs sector-aligned buffers, which is why every size here is a
//! multiple of 4096); Linux and Android use O_DIRECT (to Rust they are different targets, so
//! both are named) and also drop the file from the page cache before reading it, because some
//! filesystems accept O_DIRECT and buffer anyway. Works on any drive the user can write to.

use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiskSpeedResult {
    pub write_mbps: f64,
    pub read_mbps: f64,
    pub random_read_iops: Option<f64>,
    pub timestamp: u64,
    #[serde(default)]
    pub target: String,
    #[serde(default)]
    pub size_mb: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DiskPhase {
    #[default]
    Idle,
    Writing,
    Reading,
    RandomRead,
}

#[derive(Debug, Clone, Default)]
pub struct DiskTestState {
    pub running: bool,
    pub phase: DiskPhase,
    pub progress: f64,
    pub last_result: Option<DiskSpeedResult>,
    pub history: Vec<DiskSpeedResult>,
    pub last_error: Option<String>,
    /// What is being (or was last) tested: "C:\", a folder name…
    pub target_label: String,
}

const BLOCK: usize = 16 * 1024 * 1024;
const RANDOM_COUNT: usize = 2000;
const RANDOM_BLOCK: usize = 4096;
pub const MAX_HISTORY: usize = 10;

type Notify = Arc<dyn Fn() + Send + Sync>;

struct AlignedBuf {
    raw: Vec<u8>,
    off: usize,
    len: usize,
}

impl AlignedBuf {
    fn new(len: usize) -> Self {
        let raw = vec![0u8; len + 4096];
        let off = (4096 - (raw.as_ptr() as usize % 4096)) % 4096;
        Self { raw, off, len }
    }
    fn as_slice(&self) -> &[u8] {
        &self.raw[self.off..self.off + self.len]
    }
    fn as_mut(&mut self) -> &mut [u8] {
        &mut self.raw[self.off..self.off + self.len]
    }
}

fn open_uncached(path: &Path, write: bool) -> std::io::Result<std::fs::File> {
    let mut o = std::fs::OpenOptions::new();
    if write {
        o.write(true).create(true).truncate(true);
    } else {
        o.read(true);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_NO_BUFFERING: u32 = 0x2000_0000;
        const FILE_FLAG_WRITE_THROUGH: u32 = 0x8000_0000;
        o.custom_flags(FILE_FLAG_NO_BUFFERING | if write { FILE_FLAG_WRITE_THROUGH } else { 0 });
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.custom_flags(libc::O_DIRECT);
    }
    let opened = o.open(path);
    // Some Android storage refuses O_DIRECT outright. Reads then go through the cache, which
    // `drop_cached` has emptied of this file.
    #[cfg(target_os = "android")]
    if matches!(&opened, Err(e) if e.raw_os_error() == Some(libc::EINVAL)) {
        use std::os::unix::fs::OpenOptionsExt;
        o.custom_flags(0);
        return o.open(path);
    }
    opened
}

/// Evicts the (already synced) file from the page cache, so the reads that follow come from the
/// drive. `random` also turns readahead off for the 4 KB reads.
fn drop_cached(file: &std::fs::File, random: bool) {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: advice about a descriptor we own; length 0 means the whole file. It can't
        // fail in a way that matters here.
        unsafe {
            libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_DONTNEED);
            if random {
                libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_RANDOM);
            }
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let _ = (file, random);
}

/// Runs the benchmark synchronously in `dir`. `progress(phase, 0…1)`; polls `cancelled`.
pub fn run(
    size_mb: u32,
    dir: &Path,
    progress: &dyn Fn(DiskPhase, f64),
    cancelled: &dyn Fn() -> bool,
) -> Result<Option<DiskSpeedResult>, String> {
    let total = size_mb as usize * 1_000_000;
    let path: PathBuf = dir.join(format!(
        "blip-speedtest-{}-{}.bin",
        std::process::id(),
        crate::model::now_unix()
    ));
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let _cleanup = Cleanup(path.clone());

    let mut buf = AlignedBuf::new(BLOCK);
    for (i, b) in buf.as_mut().iter_mut().enumerate() {
        *b = (i as u32).wrapping_mul(2_654_435_761) as u8;
    }

    // Write.
    let mut f = open_uncached(&path, true).map_err(|e| e.to_string())?;
    let mut written = 0usize;
    let t0 = Instant::now();
    while written < total {
        if cancelled() {
            return Ok(None);
        }
        let chunk = BLOCK.min(total - written);
        f.write_all(&buf.as_slice()[..chunk]).map_err(|e| e.to_string())?;
        written += chunk;
        progress(DiskPhase::Writing, written as f64 / total as f64);
    }
    f.sync_all().map_err(|e| e.to_string())?;
    drop(f);
    let write_mbps = total as f64 / 1e6 / t0.elapsed().as_secs_f64().max(1e-6);

    // Read.
    let mut f = open_uncached(&path, false).map_err(|e| e.to_string())?;
    drop_cached(&f, false);
    let mut read = 0usize;
    let t0 = Instant::now();
    while read < total {
        if cancelled() {
            return Ok(None);
        }
        let chunk = BLOCK.min(total - read);
        let n = f.read(&mut buf.as_mut()[..chunk]).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        read += n;
        progress(DiskPhase::Reading, read as f64 / total as f64);
    }
    let read_mbps = read as f64 / 1e6 / t0.elapsed().as_secs_f64().max(1e-6);

    // Random 4 KB reads (aligned offsets).
    let mut iops = None;
    if !cancelled() && total > RANDOM_BLOCK {
        progress(DiskPhase::RandomRead, 0.0);
        // The sequential pass may have left the file cached.
        drop_cached(&f, true);
        let mut small = AlignedBuf::new(RANDOM_BLOCK);
        let slots = (total / RANDOM_BLOCK - 1) as u64;
        let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut done = 0usize;
        let t0 = Instant::now();
        for i in 0..RANDOM_COUNT {
            if cancelled() {
                break;
            }
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let off = (seed % slots) * RANDOM_BLOCK as u64;
            if f.seek(SeekFrom::Start(off)).is_err() {
                break;
            }
            match f.read(small.as_mut()) {
                Ok(n) if n > 0 => done += 1,
                _ => break,
            }
            if i % 128 == 0 {
                progress(DiskPhase::RandomRead, i as f64 / RANDOM_COUNT as f64);
            }
        }
        let el = t0.elapsed().as_secs_f64();
        if el > 0.0 && done > 0 {
            iops = Some(done as f64 / el);
        }
    }
    Ok(Some(DiskSpeedResult {
        write_mbps,
        read_mbps,
        random_read_iops: iops,
        timestamp: crate::model::now_unix(),
        target: dir.display().to_string(),
        size_mb,
    }))
}

/// Observable driver for the disk panel: one run at a time on a worker thread.
#[derive(Clone)]
pub struct DiskTester {
    state: Arc<Mutex<DiskTestState>>,
    cancel: Arc<AtomicBool>,
    history_path: Option<PathBuf>,
    notify: Arc<Mutex<Option<Notify>>>,
}

impl DiskTester {
    pub fn new(history_path: Option<PathBuf>) -> Self {
        let history: Vec<DiskSpeedResult> = history_path
            .as_ref()
            .and_then(|p| crate::paths::load_json(p))
            .unwrap_or_default();
        Self {
            state: Arc::new(Mutex::new(DiskTestState {
                last_result: history.last().cloned(),
                history,
                ..Default::default()
            })),
            cancel: Arc::new(AtomicBool::new(false)),
            history_path,
            notify: Arc::new(Mutex::new(None)),
        }
    }

    pub fn set_notify(&self, f: Arc<dyn Fn() + Send + Sync>) {
        *self.notify.lock().unwrap() = Some(f);
    }

    fn changed(&self) {
        if let Some(f) = self.notify.lock().unwrap().clone() {
            f();
        }
    }

    pub fn state(&self) -> DiskTestState {
        self.state.lock().unwrap().clone()
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    /// Starts a run in `dir` (a writable folder on the drive under test).
    pub fn start(&self, size_mb: u32, dir: PathBuf, label: String) {
        {
            let mut s = self.state.lock().unwrap();
            if s.running {
                return;
            }
            s.running = true;
            s.phase = DiskPhase::Writing;
            s.progress = 0.0;
            s.last_error = None;
            s.target_label = label;
        }
        self.cancel.store(false, Ordering::Relaxed);
        self.changed();
        let me = self.clone();
        std::thread::Builder::new()
            .name("blip-disktest".into())
            .spawn(move || {
                let r = me.run_now(size_mb, &dir);
                me.record(r);
            })
            .ok();
    }

    /// Blocking run (CLI).
    pub fn run_blocking(&self, size_mb: u32, dir: &Path) -> Result<Option<DiskSpeedResult>, String> {
        {
            let mut s = self.state.lock().unwrap();
            s.running = true;
            s.target_label = dir.display().to_string();
        }
        self.cancel.store(false, Ordering::Relaxed);
        let r = self.run_now(size_mb, dir);
        self.record(r.clone());
        r
    }

    fn run_now(&self, size_mb: u32, dir: &Path) -> Result<Option<DiskSpeedResult>, String> {
        let state = self.state.clone();
        let me = self.clone();
        let cancel = self.cancel.clone();
        run(
            size_mb,
            dir,
            &move |phase, p| {
                {
                    let mut s = state.lock().unwrap();
                    s.phase = phase;
                    s.progress = p;
                }
                me.changed();
            },
            &move || cancel.load(Ordering::Relaxed),
        )
    }

    fn record(&self, r: Result<Option<DiskSpeedResult>, String>) {
        let mut s = self.state.lock().unwrap();
        s.running = false;
        s.phase = DiskPhase::Idle;
        s.progress = 0.0;
        match r {
            Ok(Some(mut res)) => {
                if !s.target_label.is_empty() {
                    res.target = s.target_label.clone();
                }
                s.last_result = Some(res.clone());
                s.history.push(res);
                let excess = s.history.len().saturating_sub(MAX_HISTORY);
                s.history.drain(..excess);
                if let Some(p) = &self.history_path {
                    crate::paths::save_json(p, &s.history);
                }
            }
            Ok(None) => {}
            Err(e) => s.last_error = Some(e),
        }
        drop(s);
        self.changed();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn benchmarks_a_temp_dir() {
        let dir = std::env::temp_dir();
        let r = run(8, &dir, &|_, _| {}, &|| false).expect("run").expect("result");
        assert!(r.write_mbps > 0.0 && r.read_mbps > 0.0);
        assert!(r.random_read_iops.unwrap_or(0.0) > 0.0);
    }

    #[test]
    fn results_carry_the_label_picked() {
        // Its own folder: scratch names are per process and second, shared by parallel tests.
        let dir = std::env::temp_dir().join(format!("blip-label-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let tester = DiskTester::new(None);
        tester.start(8, dir.clone(), "Internal storage".into());
        while tester.state().running {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let state = tester.state();
        assert_eq!(state.last_error, None);
        assert_eq!(state.last_result.expect("result").target, "Internal storage");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn cancelled_run_leaves_no_file() {
        let dir = std::env::temp_dir().join(format!("blip-dt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(run(8, &dir, &|_, _| {}, &|| true).unwrap().is_none());
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(dir);
    }
}
