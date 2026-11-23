//! The Windows-native layer. Everything here runs as a standard user.

pub mod adapters;
pub mod battery;
pub mod d3d;
pub mod dev;
pub mod gpu;
pub mod icmp;
pub mod icons;
pub mod pdh;
pub mod power;
pub mod process;
pub mod storage;
pub mod system;

use std::time::Instant;

use blip_core::model::{Snapshot, ThermalLevel};

use crate::generic::LoadAvg;

/// WinRT calls need a COM apartment on the calling thread; join the MTA once per thread.
pub fn ensure_winrt() {
    thread_local!(static INIT: () = {
        // SAFETY: balanced for the thread's lifetime; S_FALSE/RPC_E_CHANGED_MODE are fine.
        unsafe {
            let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED);
        }
    });
    INIT.with(|_| {});
}

pub struct WinSampler {
    pdh: Option<pdh::Pdh>,
    net: adapters::NetSampler,
    adapters: Vec<gpu::Adapter>,
    nvml: Option<gpu::Nvml>,
    drives: Vec<blip_core::model::DriveHealth>,
    drives_at: Option<Instant>,
    os: (String, String),
    model: (String, String),
    cpu_model: Option<String>,
    topology: (usize, usize, usize),
}

impl Default for WinSampler {
    fn default() -> Self {
        Self::new()
    }
}

impl WinSampler {
    pub fn new() -> Self {
        let pdh = pdh::Pdh::new().map(|mut p| {
            p.add("cpu_user", "\\Processor(_Total)\\% User Time");
            p.add("cpu_priv", "\\Processor(_Total)\\% Privileged Time");
            p.add(
                "cpu_perf",
                "\\Processor Information(_Total)\\% Processor Performance",
            );
            p.add("cpu_freq", "\\Processor Information(_Total)\\Processor Frequency");
            p.add("queue", "\\System\\Processor Queue Length");
            p.add("disk_read", "\\PhysicalDisk(_Total)\\Disk Read Bytes/sec");
            p.add("disk_write", "\\PhysicalDisk(_Total)\\Disk Write Bytes/sec");
            p.add("disk_idle", "\\PhysicalDisk(_Total)\\% Idle Time");
            p.add("gpu_engine", "\\GPU Engine(*)\\Utilization Percentage");
            p.add("gpu_dedicated", "\\GPU Adapter Memory(*)\\Dedicated Usage");
            p.add("gpu_shared", "\\GPU Adapter Memory(*)\\Shared Usage");
            if !p.add(
                "thermal",
                "\\Thermal Zone Information(*)\\High Precision Temperature",
            ) {
                p.add("thermal_k", "\\Thermal Zone Information(*)\\Temperature");
            }
            p.add("pagefile", "\\Paging File(_Total)\\% Usage");
            p.add("cache", "\\Memory\\Cache Bytes");
            p.add("standby", "\\Memory\\Standby Cache Normal Priority Bytes");
            p.add("modified", "\\Memory\\Modified Page List Bytes");
            p.add("committed", "\\Memory\\Committed Bytes");
            p.add("commit_limit", "\\Memory\\Commit Limit");
            p.add("pool_paged", "\\Memory\\Pool Paged Bytes");
            p.add("pool_nonpaged", "\\Memory\\Pool Nonpaged Bytes");
            p.collect();
            p
        });
        Self {
            pdh,
            net: adapters::NetSampler::new(),
            adapters: gpu::adapters(),
            nvml: gpu::Nvml::load(),
            drives: Vec::new(),
            drives_at: None,
            os: system::os_name_version(),
            model: system::model(),
            cpu_model: system::cpu_model(),
            topology: system::core_topology(),
        }
    }

    pub fn sample(&mut self, s: &mut Snapshot, dt: f64, load: &mut LoadAvg) {
        // Identity
        s.system.os_name = self.os.0.clone();
        s.system.os_version = self.os.1.clone();
        if !self.model.0.is_empty() {
            s.system.model = self.model.0.clone();
        }
        if !self.model.1.is_empty() {
            s.system.manufacturer = self.model.1.clone();
        }
        s.system.uptime_secs = system::uptime_secs();
        if let Some(m) = &self.cpu_model {
            s.cpu.model = m.clone();
        }
        let (phys, p, e) = self.topology;
        if phys > 0 {
            s.cpu.physical_cores = phys;
            s.cpu.performance_cores = p;
            s.cpu.efficiency_cores = e;
        }

        if let Some(pdh) = &self.pdh {
            pdh.collect();
            // CPU
            if let (Some(u), Some(k)) = (pdh.value("cpu_user"), pdh.value("cpu_priv")) {
                s.cpu.user = u.clamp(0.0, 100.0);
                s.cpu.system = k.clamp(0.0, 100.0);
            }
            s.cpu.performance_pct = pdh.value("cpu_perf");
            if let Some(f) = pdh.value("cpu_freq").filter(|f| *f > 0.0) {
                // Base clock × performance % = the effective clock Task Manager shows.
                let eff = f * s.cpu.performance_pct.unwrap_or(100.0) / 100.0;
                s.cpu.frequency_mhz = Some(eff as u64);
            }
            // Unix load ≈ threads running + threads waiting for a CPU.
            let running = s.cpu.total / 100.0 * s.cpu.logical_cores as f64;
            let queue = pdh.value("queue").unwrap_or(0.0);
            s.cpu.load = load.update(running + queue, dt);

            // Disk I/O
            if let (Some(r), Some(w)) = (pdh.value("disk_read"), pdh.value("disk_write")) {
                s.disk.read_bps = r as u64;
                s.disk.write_bps = w as u64;
            }
            s.disk.active_pct = pdh.value("disk_idle").map(|i| (100.0 - i).clamp(0.0, 100.0));

            // Memory
            if let (Some(c), Some(l)) = (pdh.value("committed"), pdh.value("commit_limit")) {
                s.memory.committed = c as u64;
                s.memory.commit_limit = l as u64;
            }
            let standby = pdh.value("standby").unwrap_or(0.0) + pdh.value("modified").unwrap_or(0.0);
            s.memory.cached = (standby + pdh.value("cache").unwrap_or(0.0)) as u64;
            s.memory.paged_pool = pdh.value("pool_paged").map(|v| v as u64);
            s.memory.nonpaged_pool = pdh.value("pool_nonpaged").map(|v| v as u64);
            if let Some(pct) = pdh.value("pagefile") {
                let pagefile_total = s.memory.commit_limit.saturating_sub(s.memory.total);
                s.memory.swap_total = pagefile_total;
                s.memory.swap_used = (pagefile_total as f64 * pct / 100.0) as u64;
            }

            // GPU
            gpu::fill(&mut s.gpu, &self.adapters, pdh, self.nvml.as_ref());

            // Thermal zones (ACPI). High Precision is tenths of a kelvin; the plain counter kelvin.
            let tenths = pdh.has("thermal");
            for (name, v) in pdh.array(if tenths { "thermal" } else { "thermal_k" }) {
                let c = if tenths { v / 10.0 - 273.15 } else { v - 273.15 };
                if (5.0..130.0).contains(&c) {
                    let short = name
                        .rsplit('.')
                        .next()
                        .unwrap_or(&name)
                        .trim_start_matches("\\_TZ")
                        .to_string();
                    s.thermal.zones.push((short, c));
                }
            }
        }

        // Processes: the memory column should be the private working set; sysinfo's working set
        // is close enough and avoids a second process walk.
        s.thermal.gpu_c = s.gpu.temperature_c;
        s.thermal.cpu_c = s.thermal.zones.iter().map(|z| z.1).reduce(f64::max);
        if let Some(n) = &self.nvml {
            if let Some(pct) = n.fan_pct() {
                s.thermal.fans.push(blip_core::model::Fan {
                    name: "GPU".into(),
                    rpm: pct,
                    min_rpm: None,
                    max_rpm: Some(100),
                });
            }
        }
        let perf = s.cpu.performance_pct.unwrap_or(100.0);
        s.thermal.throttling = s.cpu.total > 50.0 && perf < 80.0;
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

        battery::sample(&mut s.battery);

        if self.drives_at.is_none_or(|t| t.elapsed().as_secs() >= 60) {
            self.drives = storage::drives();
            self.drives_at = Some(Instant::now());
        }
        s.disk.drives = self.drives.clone();

        self.net.sample(&mut s.network, dt);
    }
}
