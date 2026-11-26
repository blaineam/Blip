//! The bridge's real API — no JNI types, so it's unit-tested on any host.

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use blip_core::bench::{BenchEngine, BenchState, Phase, Profile, ThermalSource};
use blip_core::disktest::{DiskPhase, DiskTester};
use blip_core::geoip::{GeoDb, GeoStatus};
use blip_core::speedtest::{ExternalRun, SpeedPhase, SpeedTester};
use blip_platform::net::Traceroute;
use serde_json::{json, Value};

struct Core {
    bench: BenchEngine,
    speed: SpeedTester,
    disk: DiskTester,
    trace: Traceroute,
    geo: GeoDb,
    external: Mutex<Option<ExternalRun>>,
}

static CORE: OnceLock<Core> = OnceLock::new();

/// The app pushes Android's thermal status (and battery temperature) here; the bench samples it.
static THERMAL_STATE: AtomicI32 = AtomicI32::new(0);
static TEMPERATURE_BITS: AtomicU64 = AtomicU64::new(u64::MAX);
static INITIALIZED: AtomicBool = AtomicBool::new(false);

struct AppThermal;

impl ThermalSource for AppThermal {
    fn temperature_c(&self) -> Option<f64> {
        let bits = TEMPERATURE_BITS.load(Ordering::Relaxed);
        (bits != u64::MAX).then(|| f64::from_bits(bits))
    }
    fn fan_rpm(&self) -> Option<f64> {
        None
    }
    fn thermal_state(&self) -> i32 {
        THERMAL_STATE.load(Ordering::Relaxed)
    }
}

/// Call once from `Application.onCreate`: where Blip keeps its files (the app's files dir), the
/// UI language ("de-DE"), and the device's marketing name and Android version for bench results.
pub fn init(data_dir: &str, language: &str, device_model: &str, os_version: &str) {
    if INITIALIZED.swap(true, Ordering::SeqCst) {
        blip_core::i18n::set_language(language);
        return;
    }
    // SAFETY-free: set before any other thread reads the environment (no core threads yet).
    std::env::set_var("BLIP_DATA_DIR", data_dir);
    blip_core::i18n::set_language(language);
    let _ = std::fs::create_dir_all(data_dir);
    let model = device_model.to_string();
    let os = os_version.to_string();
    CORE.get_or_init(|| {
        let geo = GeoDb::new();
        // Off the caller's thread: the app calls this from the UI thread at launch, and the
        // database is large. Then the monthly DB-IP refresh (a no-op when absent or current).
        let loading = geo.clone();
        std::thread::spawn(move || {
            loading.load_if_present();
            loading.auto_update_check(None);
        });
        Core {
            bench: BenchEngine::new(
                Arc::new(AppThermal),
                blip_platform::gpu_compute(),
                model,
                os,
                Some(blip_core::paths::bench_history_file()),
            ),
            speed: SpeedTester::new(
                Arc::new(blip_platform::ping),
                Some(blip_core::paths::speed_history_file()),
            ),
            disk: DiskTester::new(Some(blip_core::paths::disk_history_file())),
            trace: Traceroute::new(),
            geo,
            external: Mutex::new(None),
        }
    });
}

fn core() -> &'static Core {
    if CORE.get().is_none() {
        let tmp = std::env::temp_dir().join("blip");
        init(&tmp.display().to_string(), "en-US", "Android", "");
    }
    CORE.get().expect("core initialised")
}

pub fn set_thermal(state: i32, temperature_c: f64) {
    THERMAL_STATE.store(state.clamp(0, 3), Ordering::Relaxed);
    let bits = if temperature_c.is_finite() && temperature_c > -50.0 {
        temperature_c.to_bits()
    } else {
        u64::MAX
    };
    TEMPERATURE_BITS.store(bits, Ordering::Relaxed);
}

// --- Blip Bench --------------------------------------------------------------------------

pub fn bench_start(quick: bool) {
    let c = core();
    if !c.bench.is_running() {
        c.bench
            .start(if quick { Profile::Quick } else { Profile::Full }, None);
    }
}

pub fn bench_cancel() {
    core().bench.cancel();
}

fn phase_id(p: Phase) -> &'static str {
    match p {
        Phase::Idle => "idle",
        Phase::SingleCore => "single",
        Phase::MultiCore => "multi",
        Phase::Memory => "memory",
        Phase::Gpu => "gpu",
        Phase::Neural => "neural",
        Phase::Sustained => "sustained",
        Phase::Done => "done",
    }
}

pub fn bench_state_json(s: &BenchState, best: Option<f64>) -> Value {
    json!({
        "running": s.running,
        "phase": phase_id(s.phase),
        "phaseLabel": s.phase.label(),
        "progress": s.progress,
        "legs": s.live_legs.iter().map(|l| json!({"id": l.id, "name": l.name, "score": l.score})).collect::<Vec<_>>(),
        "thermal": s.live_thermal,
        "last": s.last_result,
        "history": s.history,
        "best": best,
    })
}

pub fn bench_state() -> String {
    let c = core();
    bench_state_json(&c.bench.state(), c.bench.personal_best()).to_string()
}

// --- Speed test ----------------------------------------------------------------------------

/// Returns an error message if the address isn't usable.
pub fn speed_start_self_hosted(raw: &str) -> Option<String> {
    let Some(base) = blip_core::speedtest::normalize_base(raw) else {
        return Some(blip_core::t("Set your server's address in Settings."));
    };
    let c = core();
    if !c.speed.is_running() {
        c.speed.start_self_hosted(base);
    }
    None
}

/// Starts a public run: latency is measured here, then the app opens OpenSpeedTest's widget in
/// a hidden WebView and reports its numbers through `speed_external_*`. False if busy.
pub fn speed_begin_external() -> bool {
    let c = core();
    match c.speed.begin_external() {
        Some(run) => {
            *c.external.lock().unwrap() = Some(run);
            true
        }
        None => false,
    }
}

pub fn speed_external_progress(upload: bool, mbps: f64) {
    if let Some(run) = core().external.lock().unwrap().as_mut() {
        run.progress(upload, (mbps > 0.0).then_some(mbps));
    }
}

pub fn speed_external_complete(down: f64, up: f64) {
    if let Some(run) = core().external.lock().unwrap().take() {
        run.complete(down, (up > 0.0).then_some(up));
    }
}

pub fn speed_external_fail(message: &str) {
    if let Some(run) = core().external.lock().unwrap().take() {
        run.fail(message);
    }
}

/// Whether the in-flight public run was cancelled (the WebView should close).
pub fn speed_external_cancelled() -> bool {
    core()
        .external
        .lock()
        .unwrap()
        .as_ref()
        .is_none_or(|r| r.is_cancelled())
}

pub fn speed_cancel() {
    let c = core();
    c.speed.cancel();
    if let Some(run) = c.external.lock().unwrap().take() {
        run.fail(&blip_core::t("Cancelled"));
    }
}

pub fn speed_state() -> String {
    let s = core().speed.state();
    let (phase, error) = match &s.phase {
        SpeedPhase::Idle => ("idle", None),
        SpeedPhase::Latency => ("latency", None),
        SpeedPhase::Download => ("download", None),
        SpeedPhase::Upload => ("upload", None),
        SpeedPhase::Done => ("done", None),
        SpeedPhase::Failed(m) => ("failed", Some(m.clone())),
    };
    json!({
        "phase": phase,
        "error": error,
        "running": s.phase.is_running(),
        "liveMbps": s.live_mbps,
        "down": s.down_curve,
        "up": s.up_curve,
        "last": s.last_result,
        "history": s.history,
    })
    .to_string()
}

// --- Disk test -----------------------------------------------------------------------------

pub fn disk_start(dir: &str, size_mb: u32, label: &str) {
    let c = core();
    if !c.disk.state().running {
        c.disk.start(size_mb.clamp(64, 4096), dir.into(), label.into());
    }
}

pub fn disk_cancel() {
    core().disk.cancel();
}

pub fn disk_state() -> String {
    let s = core().disk.state();
    json!({
        "running": s.running,
        "phase": match s.phase {
            DiskPhase::Idle => "idle",
            DiskPhase::Writing => "write",
            DiskPhase::Reading => "read",
            DiskPhase::RandomRead => "random",
        },
        "progress": s.progress,
        "last": s.last_result,
        "history": s.history,
        "error": s.last_error,
        "target": s.target_label,
    })
    .to_string()
}

// --- Ping, traceroute, GeoIP -----------------------------------------------------------------

/// Round-trip time in ms, or a negative number when nothing answered.
pub fn ping(host: &str) -> f64 {
    blip_platform::ping(host).unwrap_or(-1.0)
}

/// Starts (or restarts) a live traceroute; returns an error message for a bad host.
pub fn trace_start(host: &str) -> Option<String> {
    core().trace.start(host.trim(), None).err()
}

pub fn trace_stop() {
    core().trace.stop();
}

pub fn trace_state() -> String {
    let c = core();
    let s = c.trace.snapshot();
    let hops: Vec<Value> = s
        .hops
        .iter()
        .map(|h| {
            let geo = (!h.host.is_empty() && blip_core::trace::is_public_ipv4(&h.host))
                .then(|| c.geo.lookup(&h.host))
                .flatten();
            json!({
                "hop": h.hop,
                "host": h.host,
                "sent": h.sent,
                "recv": h.recv,
                "loss": h.loss_pct,
                "last": h.last_ms,
                "avg": h.avg_ms,
                "best": h.best_ms,
                "worst": h.worst_ms,
                "geo": geo.map(|g| json!({"lat": g.lat, "lon": g.lon, "city": g.city, "country": g.country})),
            })
        })
        .collect();
    json!({
        "host": s.host,
        "running": s.running,
        "passes": s.passes,
        "error": s.error,
        "hops": hops,
    })
    .to_string()
}

/// Whether unprivileged ICMP works here (it does on stock Android; some ROMs lock it down).
pub fn icmp_available() -> bool {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        blip_platform::icmp::available()
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        true
    }
}

pub fn geo_status() -> String {
    match core().geo.status() {
        GeoStatus::Absent => json!({"state": "absent"}),
        GeoStatus::Downloading(p) => json!({"state": "downloading", "progress": p}),
        GeoStatus::Ready { build_epoch, kind } => {
            json!({"state": "ready", "built": build_epoch, "kind": kind})
        }
        GeoStatus::Failed(m) => json!({"state": "failed", "error": m}),
    }
    .to_string()
}

pub fn geo_download() {
    core().geo.download(None);
}

pub fn geo_remove() {
    core().geo.remove();
}

// --- WAN address, strings -----------------------------------------------------------------

/// The public address, fetched on request only (tap-to-reveal), as on every Blip. Blocking.
pub fn wan_ip() -> Option<String> {
    blip_core::wan_ip()
}

/// The shared catalog's translation of `key` (core-produced messages and bench phase names use
/// it too, so they match the UI language).
pub fn translate(key: &str) -> String {
    blip_core::t(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_round_trips() {
        let dir = std::env::temp_dir().join(format!("blip-android-test-{}", std::process::id()));
        init(&dir.display().to_string(), "de-DE", "Pixel 9", "Android 16");
        set_thermal(1, 38.5);
        assert_eq!(AppThermal.thermal_state(), 1);
        assert_eq!(AppThermal.temperature_c(), Some(38.5));
        let v: Value = serde_json::from_str(&bench_state()).unwrap();
        assert_eq!(v["running"], false);
        let v: Value = serde_json::from_str(&speed_state()).unwrap();
        assert_eq!(v["phase"], "idle");
        let v: Value = serde_json::from_str(&disk_state()).unwrap();
        assert_eq!(v["running"], false);
        let v: Value = serde_json::from_str(&trace_state()).unwrap();
        assert!(v["hops"].as_array().unwrap().is_empty());
        assert!(trace_start("not a host!").is_some());
        assert!(speed_start_self_hosted("").is_some());
        assert_eq!(translate("Memory"), "Speicher");
        let _ = std::fs::remove_dir_all(dir);
    }
}
