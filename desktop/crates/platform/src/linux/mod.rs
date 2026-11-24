//! The Linux-native layer: /proc, /sys and D-Bus. Everything here runs as the signed-in user —
//! no root, no setcap, no udev rule, no daemon of Blip's own.

pub mod battery;
pub mod bus;
pub mod gpu;
pub mod gpubench;
pub mod hwmon;
pub mod icmp;
pub mod icons;
pub mod netinfo;
pub mod power;
pub mod procfs;
pub mod storage;
pub mod system;

use std::time::Instant;

use blip_core::model::{Fan, Snapshot, ThermalLevel};

pub struct LinuxSampler {
    cpu_prev: Option<procfs::CpuTimes>,
    disk_prev: Option<(Vec<procfs::DiskCounters>, Instant)>,
    battery: battery::BatterySampler,
    gpu: gpu::GpuSampler,
    net: netinfo::NetInfo,
    drives: Vec<blip_core::model::DriveHealth>,
    drives_at: Option<Instant>,
    model: (String, String),
    cpu_model: Option<String>,
    topology: (usize, usize, usize),
    throttle: Option<(u64, Instant)>,
}

impl Default for LinuxSampler {
    fn default() -> Self {
        Self::new()
    }
}

impl LinuxSampler {
    pub fn new() -> Self {
        Self {
            cpu_prev: None,
            disk_prev: None,
            battery: battery::BatterySampler::new(),
            gpu: gpu::GpuSampler::new(),
            net: netinfo::NetInfo::new(),
            drives: Vec::new(),
            drives_at: None,
            model: system::model(),
            cpu_model: system::cpu_model(),
            topology: system::core_topology(),
            throttle: None,
        }
    }

    pub fn sample(&mut self, s: &mut Snapshot, dt: f64) {
        // Identity
        if !self.model.0.is_empty() {
            s.system.model = self.model.0.clone();
        }
        if !self.model.1.is_empty() {
            s.system.manufacturer = self.model.1.clone();
        }
        if s.cpu.model.is_empty() || s.cpu.model.chars().all(|c| c.is_ascii_digit()) {
            if let Some(m) = &self.cpu_model {
                s.cpu.model = m.clone();
            }
        }
        let (phys, p, e) = self.topology;
        if phys > 0 {
            s.cpu.physical_cores = phys;
            s.cpu.performance_cores = p;
            s.cpu.efficiency_cores = e;
        }

        // CPU: user/kernel split and clocks.
        if let Some(now) = procfs::read("/proc/stat").and_then(|t| procfs::parse_cpu_times(&t)) {
            if let Some((u, k)) = self.cpu_prev.and_then(|p| procfs::cpu_split(p, now)) {
                s.cpu.user = u;
                s.cpu.system = k;
            } else {
                s.cpu.user = s.cpu.total;
                s.cpu.system = 0.0;
            }
            self.cpu_prev = Some(now);
        }
        let (cur, base) = hwmon::cpu_clocks();
        if let Some(c) = cur {
            s.cpu.frequency_mhz = Some(c);
            if let Some(b) = base {
                s.cpu.performance_pct = Some(c as f64 / b as f64 * 100.0);
            }
        }

        // Memory
        if let Some(m) = procfs::read("/proc/meminfo").map(|t| procfs::parse_meminfo(&t)) {
            let g = |k: &str| m.get(k).copied().unwrap_or(0);
            s.memory.cached = g("Cached") + g("Buffers") + g("SReclaimable");
            // Strict overcommit (mode 2) is the only time the commit limit is enforced, as on
            // Windows; otherwise Committed_AS routinely exceeds it and means nothing.
            let strict = procfs::read_trim("/proc/sys/vm/overcommit_memory").as_deref() == Some("2");
            if strict && g("CommitLimit") > 0 {
                s.memory.committed = g("Committed_AS");
                s.memory.commit_limit = g("CommitLimit");
            }
        }
        s.memory.compressed = procfs::zram_compressed();

        // Disk I/O and active time from whole physical disks (partitions and device-mapper
        // layers would double-count).
        if let Some(text) = procfs::read("/proc/diskstats") {
            let now = procfs::parse_diskstats(&text, procfs::is_physical_disk);
            s.disk.total_read = now.iter().map(|d| d.read_bytes).sum();
            s.disk.total_written = now.iter().map(|d| d.written_bytes).sum();
            let at = Instant::now();
            if let Some((prev, pat)) = &self.disk_prev {
                let secs = at.duration_since(*pat).as_secs_f64();
                if secs > 0.0 {
                    let mut r = 0u64;
                    let mut w = 0u64;
                    let mut busiest: f64 = 0.0;
                    for d in &now {
                        if let Some(p) = prev.iter().find(|p| p.name == d.name) {
                            r += d.read_bytes.saturating_sub(p.read_bytes);
                            w += d.written_bytes.saturating_sub(p.written_bytes);
                            let busy = d.io_ms.saturating_sub(p.io_ms) as f64 / (secs * 1000.0) * 100.0;
                            busiest = busiest.max(busy.min(100.0));
                        }
                    }
                    s.disk.read_bps = (r as f64 / secs) as u64;
                    s.disk.write_bps = (w as f64 / secs) as u64;
                    s.disk.active_pct = Some(busiest);
                }
            }
            self.disk_prev = Some((now, at));
        }

        // Sensors
        let sensors = hwmon::read_sensors();
        s.thermal.cpu_c = sensors.cpu_c;
        s.thermal.zones = sensors.zones.clone();
        s.thermal.fans = sensors.fans.clone();

        self.gpu.sample(&mut s.gpu, sensors.gpu_c);
        if let Some(pct) = self.gpu.fan_pct() {
            {
                if !s.thermal.fans.iter().any(|f| f.name == "GPU") {
                    s.thermal.fans.push(Fan {
                        name: "GPU".into(),
                        rpm: pct,
                        min_rpm: None,
                        max_rpm: Some(100),
                    });
                }
            }
        }
        s.thermal.gpu_c = s.gpu.temperature_c;

        // Throttling: Pi firmware flags, Intel package throttle events, or clock < 80 % of base
        // under load (the Windows rule).
        let perf = s.cpu.performance_pct.unwrap_or(100.0);
        let events = hwmon::throttle_events().map(|v| {
            let recent = self
                .throttle
                .is_some_and(|(p, at)| v > p && at.elapsed().as_secs() < 30);
            if self.throttle.is_none_or(|(p, _)| v != p) {
                self.throttle = Some((v, Instant::now()));
            }
            recent
        });
        s.thermal.throttling = hwmon::pi_throttled().unwrap_or(false)
            || events.unwrap_or(false)
            || (s.cpu.total > 50.0 && perf < 80.0);
        let hot = s
            .thermal
            .cpu_c
            .unwrap_or(0.0)
            .max(s.gpu.temperature_c.unwrap_or(0.0));
        s.thermal.level = if hot >= 98.0 {
            ThermalLevel::Critical
        } else if hot >= 90.0 || (s.thermal.throttling && perf < 55.0) {
            ThermalLevel::Serious
        } else if hot >= 80.0 || s.thermal.throttling {
            ThermalLevel::Fair
        } else {
            ThermalLevel::Nominal
        };

        self.battery.sample(&mut s.battery);

        if self.drives_at.is_none_or(|t| t.elapsed().as_secs() >= 60) {
            self.drives = storage::drives(&sensors.drives);
            self.drives_at = Some(Instant::now());
        } else {
            // Temperatures move; refresh them from this round's sensors.
            for d in &mut self.drives {
                let name = d.id.trim_start_matches("/dev/");
                if let Ok(dev) = std::fs::canonicalize(format!("/sys/block/{name}/device")) {
                    if let Some((_, c)) = sensors.drives.iter().find(|(p, _)| *p == dev) {
                        d.temperature_c = Some(c.round() as i32);
                    }
                }
            }
        }
        s.disk.drives = self.drives.clone();

        self.net.enrich(&mut s.network);
        let _ = dt;
    }

    /// Memory pressure from PSI (kernel ≥ 4.20), merged with the generic estimate.
    pub fn pressure() -> Option<u8> {
        let text = procfs::read("/proc/pressure/memory")?;
        let (some, full) = procfs::parse_psi(&text);
        Some(procfs::psi_level(some, full))
    }
}
