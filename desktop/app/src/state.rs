//! Everything the UI reads, owned in one place. A sampler thread refreshes the snapshot and the
//! chart histories every `updateIntervalSecs`; the long-running tools (benchmark, speed tests,
//! traceroute, GeoIP) own their own threads and publish through their handles.

use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use blip_core::bench::{BenchEngine, ThermalSource};
use blip_core::disktest::DiskTester;
use blip_core::geoip::GeoDb;
use blip_core::history::History;
use blip_core::model::Snapshot;
use blip_core::recommend::Recommendation;
use blip_core::settings::{Settings, SpeedServerKind};
use blip_core::speedtest::SpeedTester;
use blip_platform::net::Traceroute;
use blip_platform::{AwakeOptions, KeepAwake};

#[derive(Default, Clone)]
pub struct Histories {
    pub cpu: History,
    pub memory: History,
    pub gpu: History,
    pub disk_read: History,
    pub disk_write: History,
    pub net_down: History,
    pub net_up: History,
    pub ping: History,
}

pub struct Live {
    pub snapshot: Snapshot,
    pub history: Histories,
    pub recommendations: Vec<Recommendation>,
    pub samples: u64,
}

/// Latest temperature for the benchmark's sustained phase, refreshed by the sampler.
#[derive(Default)]
pub struct ThermalBox(Mutex<(Option<f64>, Option<f64>, i32)>);

impl ThermalSource for ThermalBox {
    fn temperature_c(&self) -> Option<f64> {
        self.0.lock().unwrap().0
    }
    fn fan_rpm(&self) -> Option<f64> {
        self.0.lock().unwrap().1
    }
    fn thermal_state(&self) -> i32 {
        self.0.lock().unwrap().2
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AwakeSession {
    pub options: AwakeOptions,
    /// None = until turned off.
    pub until: Option<std::time::SystemTime>,
}

pub struct Shared {
    pub live: RwLock<Live>,
    pub settings: RwLock<Settings>,
    pub bench: BenchEngine,
    pub speed: SpeedTester,
    pub disk: DiskTester,
    pub trace: Traceroute,
    pub geo: GeoDb,
    pub thermal: Arc<ThermalBox>,
    pub awake: Mutex<KeepAwake>,
    pub awake_session: Mutex<Option<AwakeSession>>,
    pub wan_ip: Mutex<Option<String>>,
    repaint: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    last_auto_net: Mutex<Option<Instant>>,
    last_auto_disk: Mutex<Option<Instant>>,
}

pub type App = Arc<Shared>;

impl Shared {
    pub fn new() -> App {
        let settings = Settings::load();
        apply_language(&settings.language);
        let thermal = Arc::new(ThermalBox::default());
        let (model, os) = {
            let s = blip_platform::snapshot_once(Duration::from_millis(10));
            (
                if s.system.model.is_empty() {
                    s.cpu.model.clone()
                } else {
                    s.system.model.clone()
                },
                format!("{} {}", s.system.os_name, s.system.os_version),
            )
        };
        let bench = BenchEngine::new(
            thermal.clone(),
            blip_platform::gpu_compute(),
            model,
            os,
            Some(blip_core::paths::bench_history_file()),
        );
        let speed = SpeedTester::new(
            Arc::new(blip_platform::ping),
            Some(blip_core::paths::speed_history_file()),
        );
        let disk = DiskTester::new(Some(blip_core::paths::disk_history_file()));
        Arc::new(Self {
            live: RwLock::new(Live {
                snapshot: Snapshot::default(),
                history: Histories::default(),
                recommendations: Vec::new(),
                samples: 0,
            }),
            settings: RwLock::new(settings),
            bench,
            speed,
            disk,
            trace: Traceroute::new(),
            geo: GeoDb::new(),
            thermal,
            awake: Mutex::new(KeepAwake::new()),
            awake_session: Mutex::new(None),
            wan_ip: Mutex::new(None),
            repaint: Mutex::new(None),
            last_auto_net: Mutex::new(None),
            last_auto_disk: Mutex::new(None),
        })
    }

    pub fn set_repaint(&self, f: Arc<dyn Fn() + Send + Sync>) {
        self.speed.set_notify(f.clone());
        self.disk.set_notify(f.clone());
        *self.repaint.lock().unwrap() = Some(f);
    }

    pub fn repaint(&self) {
        if let Some(f) = self.repaint.lock().unwrap().clone() {
            f();
        }
    }

    pub fn repaint_fn(&self) -> Option<Arc<dyn Fn() + Send + Sync>> {
        self.repaint.lock().unwrap().clone()
    }

    pub fn settings(&self) -> Settings {
        self.settings.read().unwrap().clone()
    }

    /// Applies a settings change and persists it.
    pub fn update_settings(&self, f: impl FnOnce(&mut Settings)) {
        let mut s = self.settings.write().unwrap();
        let before = s.clone();
        f(&mut s);
        if *s != before {
            s.save();
            if s.language != before.language {
                apply_language(&s.language);
            }
        }
    }

    pub fn snapshot(&self) -> Snapshot {
        self.live.read().unwrap().snapshot.clone()
    }

    /// Starts the sampling thread.
    pub fn start_sampler(self: &App) {
        let me = self.clone();
        std::thread::Builder::new()
            .name("blip-sampler".into())
            .spawn(move || {
                let mut sampler = blip_platform::Sampler::new();
                loop {
                    let started = Instant::now();
                    let settings = me.settings();
                    sampler.set_ping_target(&settings.ping_target);
                    let snap = sampler.sample();
                    me.ingest(snap, &settings);
                    me.housekeeping(&settings);
                    me.repaint();
                    let interval = Duration::from_secs(settings.update_interval_secs.clamp(1, 10));
                    std::thread::sleep(interval.saturating_sub(started.elapsed()));
                }
            })
            .expect("spawn sampler");
    }

    fn ingest(&self, snap: Snapshot, settings: &Settings) {
        *self.thermal.0.lock().unwrap() = (
            snap.thermal.cpu_c.or(snap.gpu.temperature_c),
            snap.thermal.fans.first().map(|f| f.rpm as f64),
            snap.thermal.level.rank(),
        );
        let mut recs = blip_core::recommend::analyze(&snap);
        recs.retain(|r| !settings.dismissed_recommendations.contains(&r.id));
        let mut live = self.live.write().unwrap();
        let first = live.samples == 0;
        live.samples += 1;
        let h = &mut live.history;
        h.cpu.push(snap.cpu.total);
        h.memory.push(snap.memory.usage_pct());
        h.gpu.push(snap.gpu.utilization);
        if !first {
            h.disk_read.push(snap.disk.read_bps as f64);
            h.disk_write.push(snap.disk.write_bps as f64);
            h.net_down.push(snap.network.down_bps as f64);
            h.net_up.push(snap.network.up_bps as f64);
        }
        if let Some(p) = snap.network.ping_ms {
            h.ping.push(p);
        }
        live.snapshot = snap;
        live.recommendations = recs;
    }

    /// Timers that live outside any panel: Keep Awake expiry + battery guard, interval speed
    /// tests (self-hosted only, never on metered networks), interval disk tests (skip worn
    /// drives), daily GeoIP refresh.
    fn housekeeping(&self, settings: &Settings) {
        let snap = self.snapshot();
        let mut session = self.awake_session.lock().unwrap();
        if let Some(s) = *session {
            let expired = s.until.is_some_and(|u| std::time::SystemTime::now() >= u);
            let low_battery = s.options.ignore_lid
                && snap.battery.present
                && !snap.battery.plugged_in
                && snap.battery.level <= 10.0;
            if expired || low_battery {
                self.awake.lock().unwrap().release();
                *session = None;
            }
        }
        drop(session);

        if settings.net_speed_auto_run
            && settings.speed_test_server_kind == SpeedServerKind::SelfHosted
            && !snap.network.metered
            && due(&self.last_auto_net, settings.net_speed_interval)
            && !self.speed.is_running()
        {
            if let Some(base) = blip_core::speedtest::normalize_base(&settings.speed_test_open_speed_test_url)
            {
                self.speed.start_self_hosted(base);
            }
        }
        if settings.disk_speed_auto_run
            && due(&self.last_auto_disk, settings.disk_speed_interval)
            && !self.disk.state().running
        {
            let worn = snap
                .disk
                .drives
                .iter()
                .filter_map(|d| d.life_remaining())
                .any(|l| l < 30);
            if !worn {
                let (dir, label) = disk_target(settings, &snap);
                self.disk.start(settings.disk_speed_size, dir, label);
            }
        }
        if settings.geoip_auto_update {
            self.geo.auto_update_check(self.repaint_fn());
        }
    }

    pub fn start_awake(&self, minutes: u32, options: AwakeOptions) {
        let mut a = self.awake.lock().unwrap();
        a.engage(options);
        let until =
            (minutes > 0).then(|| std::time::SystemTime::now() + Duration::from_secs(minutes as u64 * 60));
        *self.awake_session.lock().unwrap() = Some(AwakeSession { options, until });
    }

    pub fn stop_awake(&self) {
        self.awake.lock().unwrap().release();
        *self.awake_session.lock().unwrap() = None;
    }

    pub fn awake(&self) -> Option<AwakeSession> {
        *self.awake_session.lock().unwrap()
    }

    pub fn start_speed_test(&self) {
        let s = self.settings();
        match s.speed_test_server_kind {
            SpeedServerKind::SelfHosted => {
                if let Some(base) = blip_core::speedtest::normalize_base(&s.speed_test_open_speed_test_url) {
                    self.speed.start_self_hosted(base);
                }
            }
            SpeedServerKind::Public => crate::publictest::start(self.speed.clone()),
        }
    }
}

/// "" = follow the OS language.
pub fn apply_language(choice: &str) {
    let tag = if choice.is_empty() {
        blip_platform::ui_language()
    } else {
        choice.to_string()
    };
    blip_core::i18n::set_language(&tag);
}

/// Interval timer: true once per `minutes` (the first call only arms it).
fn due(last: &Mutex<Option<Instant>>, minutes: u32) -> bool {
    let mut l = last.lock().unwrap();
    match *l {
        None => {
            *l = Some(Instant::now());
            false
        }
        Some(t) if t.elapsed() >= Duration::from_secs(minutes.max(5) as u64 * 60) => {
            *l = Some(Instant::now());
            true
        }
        _ => false,
    }
}

/// Where the disk test writes: the chosen folder, or the system drive's temp folder.
pub fn disk_target(settings: &Settings, snap: &Snapshot) -> (std::path::PathBuf, String) {
    if !settings.disk_speed_target.is_empty() {
        let p = std::path::PathBuf::from(&settings.disk_speed_target);
        return (p.clone(), p.display().to_string());
    }
    let label = snap
        .disk
        .system_volume()
        .map(|v| v.mount.clone())
        .unwrap_or_else(|| "System drive".into());
    (std::env::temp_dir(), label)
}

/// A writable folder on `mount` for a one-click per-volume test.
pub fn folder_on_volume(mount: &str) -> std::path::PathBuf {
    let temp = std::env::temp_dir();
    if temp
        .to_string_lossy()
        .to_ascii_lowercase()
        .starts_with(&mount.to_ascii_lowercase())
    {
        return temp;
    }
    let p = std::path::Path::new(mount).join(".blip-speedtest");
    let _ = std::fs::create_dir_all(&p);
    p
}
