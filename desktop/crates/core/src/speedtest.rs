//! Network throughput test against OpenSpeedTest servers, ported from the Mac `SpeedTester`.
//! Self-hosted servers are driven natively here (parallel HTTP streams to `/downloading` and
//! `/upload`); the public openspeedtest.com test is driven through its own widget by the app
//! layer (a hidden WebView2 on Windows), exactly as the Mac drives it through WKWebView, and
//! reports back through [`SpeedTester::begin_external`] / [`ExternalRun`].

use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NetSpeedResult {
    pub down_mbps: f64,
    pub up_mbps: Option<f64>,
    /// Unix seconds.
    pub timestamp: u64,
    pub ping_ms: Option<f64>,
    pub loaded_ping_ms: Option<f64>,
    pub down_curve: Option<Vec<f64>>,
    pub up_curve: Option<Vec<f64>>,
    /// "public" or the self-hosted base URL.
    #[serde(default)]
    pub server: String,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub enum SpeedPhase {
    #[default]
    Idle,
    Latency,
    Download,
    Upload,
    Done,
    Failed(String),
}

impl SpeedPhase {
    pub fn is_running(&self) -> bool {
        matches!(
            self,
            SpeedPhase::Latency | SpeedPhase::Download | SpeedPhase::Upload
        )
    }
}

#[derive(Debug, Clone, Default)]
pub struct SpeedState {
    pub phase: SpeedPhase,
    pub live_mbps: f64,
    pub down_curve: Vec<f64>,
    pub up_curve: Vec<f64>,
    pub last_result: Option<NetSpeedResult>,
    pub history: Vec<NetSpeedResult>,
}

/// Normalizes a self-hosted server entry: adds `http://`, drops trailing slashes.
pub fn normalize_base(raw: &str) -> Option<String> {
    let mut s = raw.trim().to_string();
    if s.is_empty() {
        return None;
    }
    let lower = s.to_ascii_lowercase();
    if !lower.starts_with("http://") && !lower.starts_with("https://") {
        s = format!("http://{s}");
    }
    while s.ends_with('/') {
        s.pop();
    }
    Some(s)
}

pub type PingFn = Arc<dyn Fn(&str) -> Option<f64> + Send + Sync>;
type Notify = Arc<dyn Fn() + Send + Sync>;

pub const MAX_HISTORY: usize = 10;
const PARALLELISM: usize = 6;
const PHASE_SECONDS: f64 = 8.0;
const WARMUP_SECONDS: f64 = 1.5;
const UPLOAD_CHUNK: usize = 25_000_000;

#[derive(Clone)]
pub struct SpeedTester {
    state: Arc<Mutex<SpeedState>>,
    cancel: Arc<AtomicBool>,
    ping: PingFn,
    latency_host: String,
    history_path: Option<std::path::PathBuf>,
    notify: Arc<Mutex<Option<Notify>>>,
}

impl SpeedTester {
    pub fn new(ping: PingFn, history_path: Option<std::path::PathBuf>) -> Self {
        let history: Vec<NetSpeedResult> = history_path
            .as_ref()
            .and_then(|p| crate::paths::load_json(p))
            .unwrap_or_default();
        Self {
            state: Arc::new(Mutex::new(SpeedState {
                last_result: history.last().cloned(),
                history,
                ..Default::default()
            })),
            cancel: Arc::new(AtomicBool::new(false)),
            ping,
            latency_host: "1.1.1.1".into(),
            history_path,
            notify: Arc::new(Mutex::new(None)),
        }
    }

    pub fn set_notify(&self, f: Notify) {
        *self.notify.lock().unwrap() = Some(f);
    }

    fn changed(&self) {
        if let Some(f) = self.notify.lock().unwrap().clone() {
            f();
        }
    }

    pub fn state(&self) -> SpeedState {
        self.state.lock().unwrap().clone()
    }

    pub fn is_running(&self) -> bool {
        self.state.lock().unwrap().phase.is_running()
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
        let mut s = self.state.lock().unwrap();
        if s.phase.is_running() {
            s.phase = SpeedPhase::Idle;
            s.live_mbps = 0.0;
        }
        drop(s);
        self.changed();
    }

    fn reset_for_run(&self) -> bool {
        let mut s = self.state.lock().unwrap();
        if s.phase.is_running() {
            return false;
        }
        s.phase = SpeedPhase::Latency;
        s.live_mbps = 0.0;
        s.down_curve.clear();
        s.up_curve.clear();
        self.cancel.store(false, Ordering::Relaxed);
        true
    }

    /// Starts a self-hosted run on worker threads.
    pub fn start_self_hosted(&self, base: String) {
        if !self.reset_for_run() {
            return;
        }
        let me = self.clone();
        std::thread::spawn(move || {
            let r = me.run_self_hosted(&base);
            me.finish(r);
        });
        self.changed();
    }

    /// Blocking self-hosted run (CLI).
    pub fn run_self_hosted_blocking(&self, base: &str) -> Result<NetSpeedResult, String> {
        if !self.reset_for_run() {
            return Err("A network speed test is already running.".into());
        }
        let r = self.run_self_hosted(base);
        self.finish(r.clone());
        r
    }

    fn finish(&self, r: Result<NetSpeedResult, String>) {
        let mut s = self.state.lock().unwrap();
        s.live_mbps = 0.0;
        match r {
            Ok(res) => {
                s.last_result = Some(res.clone());
                s.history.push(res);
                let excess = s.history.len().saturating_sub(MAX_HISTORY);
                s.history.drain(..excess);
                if let Some(p) = &self.history_path {
                    crate::paths::save_json(p, &s.history);
                }
                s.phase = SpeedPhase::Done;
            }
            Err(e) if e == CANCELLED => s.phase = SpeedPhase::Idle,
            Err(e) => s.phase = SpeedPhase::Failed(e),
        }
        drop(s);
        self.changed();
    }

    fn set_phase(&self, p: SpeedPhase) {
        let mut s = self.state.lock().unwrap();
        s.phase = p;
        s.live_mbps = 0.0;
        drop(s);
        self.changed();
    }

    fn capture_live(&self, mbps: f64, upload: bool) {
        let mut s = self.state.lock().unwrap();
        s.live_mbps = mbps;
        let curve = if upload {
            &mut s.up_curve
        } else {
            &mut s.down_curve
        };
        curve.push(mbps);
        if curve.len() > 240 {
            curve.remove(0);
        }
        drop(s);
        self.changed();
    }

    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    fn median_ping(&self, count: usize) -> Option<f64> {
        let mut rtts = Vec::new();
        for _ in 0..count {
            if self.cancelled() {
                break;
            }
            if let Some(r) = (self.ping)(&self.latency_host) {
                rtts.push(r);
            }
            std::thread::sleep(Duration::from_millis(120));
        }
        median(&mut rtts)
    }

    fn run_self_hosted(&self, base: &str) -> Result<NetSpeedResult, String> {
        let unloaded = self.median_ping(5);
        if self.cancelled() {
            return Err(CANCELLED.into());
        }
        self.set_phase(SpeedPhase::Download);
        let loaded = LoadedProbe::start(self.ping.clone(), self.latency_host.clone());
        let down = self.measure(base, false);
        let loaded_ms = loaded.stop();
        let down = down?;
        self.set_phase(SpeedPhase::Upload);
        let up = self.measure(base, true)?;
        let s = self.state();
        Ok(NetSpeedResult {
            down_mbps: down,
            up_mbps: Some(up),
            timestamp: crate::model::now_unix(),
            ping_ms: unloaded,
            loaded_ping_ms: loaded_ms,
            down_curve: downsample(&s.down_curve, 80),
            up_curve: downsample(&s.up_curve, 80),
            server: base.to_string(),
        })
    }

    /// `PARALLELISM` streams for `PHASE_SECONDS`; Mbps over the window data actually flowed,
    /// warm-up excluded — the Mac's measurement exactly.
    fn measure(&self, base: &str, upload: bool) -> Result<f64, String> {
        let bytes = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let start = Instant::now();
        let deadline = start + Duration::from_secs_f64(PHASE_SECONDS);
        let body: Arc<Vec<u8>> = Arc::new(if upload {
            vec![0u8; UPLOAD_CHUNK]
        } else {
            Vec::new()
        });
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_connect(Some(Duration::from_secs(5)))
            .timeout_global(Some(Duration::from_secs(30)))
            .build()
            .into();
        let mut workers = Vec::new();
        for i in 0..PARALLELISM {
            let (bytes, stop, error, body, agent, cancel) = (
                bytes.clone(),
                stop.clone(),
                error.clone(),
                body.clone(),
                agent.clone(),
                self.cancel.clone(),
            );
            let base = base.to_string();
            workers.push(std::thread::spawn(move || {
                let mut n = i as u64;
                while !stop.load(Ordering::Relaxed) && !cancel.load(Ordering::Relaxed) && Instant::now() < deadline {
                    n = n.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    let res = if upload {
                        let url = format!("{base}/upload?r={n}");
                        let reader = CountingReader {
                            data: body.clone(),
                            pos: 0,
                            counter: bytes.clone(),
                            stop: stop.clone(),
                            cancel: cancel.clone(),
                        };
                        agent
                            .post(&url)
                            .header("Content-Type", "application/octet-stream")
                            .send(ureq::SendBody::from_owned_reader(reader))
                            .map(|_| ())
                    } else {
                        let url = format!("{base}/downloading?r={n}");
                        agent.get(&url).call().map(|mut resp| {
                            let mut reader = resp.body_mut().as_reader();
                            let mut buf = vec![0u8; 256 * 1024];
                            loop {
                                if stop.load(Ordering::Relaxed) || cancel.load(Ordering::Relaxed) {
                                    break;
                                }
                                match reader.read(&mut buf) {
                                    Ok(0) | Err(_) => break,
                                    Ok(k) => {
                                        bytes.fetch_add(k as u64, Ordering::Relaxed);
                                    }
                                }
                            }
                        })
                    };
                    if let Err(e) = res {
                        let msg = match e {
                            ureq::Error::StatusCode(429) => "Server busy (rate-limited). Wait a moment, or pick an OpenSpeedTest LAN server in Settings.".to_string(),
                            ureq::Error::StatusCode(403) => "Server rejected the request (403). Try an OpenSpeedTest LAN server in Settings.".to_string(),
                            ureq::Error::StatusCode(c) => format!("Server error (HTTP {c}). Try again, or use an OpenSpeedTest server."),
                            ureq::Error::Timeout(_) => "Timed out".into(),
                            _ => "Network unavailable".into(),
                        };
                        *error.lock().unwrap() = Some(msg);
                        if bytes.load(Ordering::Relaxed) == 0 {
                            break;
                        }
                    }
                }
            }));
        }

        let warmup_end = start + Duration::from_secs_f64(WARMUP_SECONDS);
        let mut at_warmup: Option<u64> = None;
        let mut last_bytes = 0u64;
        let mut last_progress = warmup_end;
        while Instant::now() < deadline {
            if self.cancelled() {
                stop.store(true, Ordering::Relaxed);
                return Err(CANCELLED.into());
            }
            std::thread::sleep(Duration::from_millis(200));
            let now = Instant::now();
            let b = bytes.load(Ordering::Relaxed);
            if at_warmup.is_none() && now >= warmup_end {
                at_warmup = Some(b);
                last_bytes = b;
                last_progress = now;
            }
            if let Some(base) = at_warmup {
                if b > last_bytes {
                    last_bytes = b;
                    last_progress = now;
                }
                let elapsed = (last_progress - warmup_end).as_secs_f64();
                if elapsed > 0.0 {
                    self.capture_live((last_bytes - base) as f64 * 8.0 / elapsed / 1e6, upload);
                }
                if (now - last_progress).as_secs_f64() > 0.5 && last_bytes > base {
                    break;
                }
            }
            let err = error.lock().unwrap().clone();
            if let Some(e) = err {
                if b == 0 && now - start > Duration::from_secs(3) {
                    stop.store(true, Ordering::Relaxed);
                    return Err(e);
                }
            }
        }
        stop.store(true, Ordering::Relaxed);
        // Workers notice `stop` on their next chunk; don't block the result on slow sockets.
        drop(workers);
        let base_bytes = at_warmup.unwrap_or(0);
        let measured = last_bytes.saturating_sub(base_bytes);
        if measured == 0 {
            return Err(error
                .lock()
                .unwrap()
                .clone()
                .unwrap_or_else(|| "Test failed".into()));
        }
        let secs = (last_progress - warmup_end).as_secs_f64().max(0.001);
        Ok(measured as f64 * 8.0 / secs / 1e6)
    }

    // ---- Public (widget-driven) runs: the app layer drives the browser, we keep the books.

    /// Begins a run whose transfers happen elsewhere (the public OpenSpeedTest widget).
    pub fn begin_external(&self) -> Option<ExternalRun> {
        if !self.reset_for_run() {
            return None;
        }
        self.changed();
        let unloaded = self.median_ping(5);
        if self.cancelled() {
            self.finish(Err(CANCELLED.into()));
            return None;
        }
        self.set_phase(SpeedPhase::Download);
        let probe = LoadedProbe::start(self.ping.clone(), self.latency_host.clone());
        Some(ExternalRun {
            tester: self.clone(),
            unloaded,
            probe: Some(probe),
            loaded: None,
            upload_started: false,
        })
    }
}

/// Book-keeping handle for a run driven by the public widget.
pub struct ExternalRun {
    tester: SpeedTester,
    unloaded: Option<f64>,
    probe: Option<LoadedProbe>,
    loaded: Option<f64>,
    upload_started: bool,
}

impl ExternalRun {
    pub fn is_cancelled(&self) -> bool {
        self.tester.cancelled()
    }

    pub fn progress(&mut self, upload: bool, mbps: Option<f64>) {
        if upload && !self.upload_started {
            self.upload_started = true;
            self.loaded = self.probe.take().and_then(|p| p.stop());
            self.tester.set_phase(SpeedPhase::Upload);
        }
        if let Some(m) = mbps {
            self.tester.capture_live(m, upload);
        }
    }

    pub fn complete(mut self, down: f64, up: Option<f64>) {
        let loaded = self.loaded.or_else(|| self.probe.take().and_then(|p| p.stop()));
        let s = self.tester.state();
        let r = NetSpeedResult {
            down_mbps: down,
            up_mbps: up,
            timestamp: crate::model::now_unix(),
            ping_ms: self.unloaded,
            loaded_ping_ms: loaded,
            down_curve: downsample(&s.down_curve, 80),
            up_curve: downsample(&s.up_curve, 80),
            server: "public".into(),
        };
        self.tester.finish(Ok(r));
    }

    pub fn fail(mut self, message: &str) {
        if let Some(p) = self.probe.take() {
            p.stop();
        }
        self.tester.finish(Err(message.to_string()));
    }
}

const CANCELLED: &str = "\u{0}cancelled";

/// Pings under load every 400 ms while a transfer runs (bufferbloat).
struct LoadedProbe {
    stop: Arc<AtomicBool>,
    handle: std::thread::JoinHandle<Vec<f64>>,
}

impl LoadedProbe {
    fn start(ping: PingFn, host: String) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let s2 = stop.clone();
        let handle = std::thread::spawn(move || {
            let mut out = Vec::new();
            while !s2.load(Ordering::Relaxed) {
                if let Some(r) = ping(&host) {
                    out.push(r);
                }
                std::thread::sleep(Duration::from_millis(400));
            }
            out
        });
        Self { stop, handle }
    }

    fn stop(self) -> Option<f64> {
        self.stop.store(true, Ordering::Relaxed);
        let mut v = self.handle.join().unwrap_or_default();
        median(&mut v)
    }
}

fn median(v: &mut [f64]) -> Option<f64> {
    if v.is_empty() {
        return None;
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    Some(v[v.len() / 2])
}

pub fn downsample(values: &[f64], target: usize) -> Option<Vec<f64>> {
    if values.is_empty() {
        return None;
    }
    if values.len() <= target {
        return Some(values.to_vec());
    }
    let stride = values.len() as f64 / target as f64;
    Some(
        (0..target)
            .map(|i| values[((i as f64 * stride) as usize).min(values.len() - 1)])
            .collect(),
    )
}

/// Upload body that counts bytes as ureq pulls them off it.
struct CountingReader {
    data: Arc<Vec<u8>>,
    pos: usize,
    counter: Arc<AtomicU64>,
    stop: Arc<AtomicBool>,
    cancel: Arc<AtomicBool>,
}

impl Read for CountingReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.stop.load(Ordering::Relaxed) || self.cancel.load(Ordering::Relaxed) {
            return Err(std::io::Error::new(std::io::ErrorKind::Interrupted, "stopped"));
        }
        let n = buf.len().min(self.data.len() - self.pos).min(256 * 1024);
        buf[..n].copy_from_slice(&self.data[self.pos..self.pos + n]);
        self.pos += n;
        self.counter.fetch_add(n as u64, Ordering::Relaxed);
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_server_entries() {
        assert_eq!(
            normalize_base("192.168.1.50:3000/").as_deref(),
            Some("http://192.168.1.50:3000")
        );
        assert_eq!(
            normalize_base(" https://ost.lan ").as_deref(),
            Some("https://ost.lan")
        );
        assert_eq!(normalize_base("  "), None);
    }

    #[test]
    fn downsamples_long_curves() {
        let v: Vec<f64> = (0..240).map(f64::from).collect();
        assert_eq!(downsample(&v, 80).unwrap().len(), 80);
        assert_eq!(downsample(&[1.0, 2.0], 80).unwrap(), vec![1.0, 2.0]);
    }

    /// End-to-end against a tiny local OpenSpeedTest-compatible server.
    #[test]
    fn measures_a_local_server() {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                std::thread::spawn(move || {
                    let mut s = stream;
                    let mut reader = BufReader::new(s.try_clone().unwrap());
                    let mut line = String::new();
                    if reader.read_line(&mut line).is_err() {
                        return;
                    }
                    let mut len = 0usize;
                    loop {
                        let mut h = String::new();
                        if reader.read_line(&mut h).is_err() || h == "\r\n" || h.is_empty() {
                            break;
                        }
                        if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
                            len = v.trim().parse().unwrap_or(0);
                        }
                    }
                    if line.starts_with("GET") {
                        let body = vec![7u8; 4_000_000];
                        let _ = write!(
                            s,
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = s.write_all(&body);
                    } else {
                        let mut sink = vec![0u8; 65536];
                        let mut left = len;
                        while left > 0 {
                            match reader.read(&mut sink[..left.min(65536)]) {
                                Ok(0) | Err(_) => break,
                                Ok(n) => left -= n,
                            }
                        }
                        let _ = write!(
                            s,
                            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        );
                    }
                });
            }
        });
        let tester = SpeedTester::new(Arc::new(|_| Some(1.0)), None);
        let r = tester
            .run_self_hosted_blocking(&format!("http://{addr}"))
            .expect("run");
        assert!(r.down_mbps > 0.0);
        assert!(r.up_mbps.unwrap_or(0.0) > 0.0);
        assert_eq!(r.ping_ms, Some(1.0));
    }
}
