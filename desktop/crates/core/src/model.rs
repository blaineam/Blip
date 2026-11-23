//! The snapshot every surface renders: tray icon, popover, detail panels, the `blip` CLI and the
//! Markdown export. Mirrors the Mac app's `SystemSnapshot` field for field where the data
//! exists on Windows/Linux; fields a platform can't supply stay `None` and the UI hides them.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CpuStats {
    /// 0–100.
    pub total: f64,
    pub user: f64,
    pub system: f64,
    pub cores: Vec<f64>,
    /// Load averages. Windows has none, so the backend derives a Unix-style exponentially-damped
    /// average from the processor queue length + running threads, the way WSL and `uptime`
    /// clones do. `None` until the first minute of samples exists.
    pub load: Option<[f64; 3]>,
    pub physical_cores: usize,
    pub logical_cores: usize,
    /// Hybrid CPUs (Intel 12th gen+, Snapdragon X): performance / efficiency core counts.
    pub performance_cores: usize,
    pub efficiency_cores: usize,
    pub model: String,
    /// Current clock as % of base (Windows "% Processor Performance"). Below ~70 under load =
    /// thermal or power throttling.
    pub performance_pct: Option<f64>,
    pub frequency_mhz: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MemoryStats {
    pub total: u64,
    pub used: u64,
    pub available: u64,
    /// Windows: modified + standby cache (file cache). Linux: page cache.
    pub cached: u64,
    /// Windows: memory compression store (from the "Memory Compression" process). Linux: zram.
    pub compressed: Option<u64>,
    /// Commit charge vs limit (Windows) — the closest analogue of macOS swap pressure.
    pub committed: u64,
    pub commit_limit: u64,
    pub paged_pool: Option<u64>,
    pub nonpaged_pool: Option<u64>,
    pub swap_used: u64,
    pub swap_total: u64,
    /// 0 = normal, 1 = warning, 2 = critical (same scale as the Mac's kernel pressure level).
    pub pressure: u8,
}

impl MemoryStats {
    pub fn usage_pct(&self) -> f64 {
        if self.total == 0 { 0.0 } else { self.used as f64 / self.total as f64 * 100.0 }
    }
    pub fn commit_pct(&self) -> f64 {
        if self.commit_limit == 0 { 0.0 } else { self.committed as f64 / self.commit_limit as f64 * 100.0 }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Volume {
    pub name: String,
    /// "C:\" on Windows, "/" on Linux.
    pub mount: String,
    pub file_system: String,
    pub total: u64,
    pub free: u64,
    pub removable: bool,
    /// The volume Windows booted from (or "/").
    pub is_system: bool,
}

impl Volume {
    pub fn used(&self) -> u64 {
        self.total.saturating_sub(self.free)
    }
    pub fn usage_pct(&self) -> f64 {
        if self.total == 0 { 0.0 } else { self.used() as f64 / self.total as f64 * 100.0 }
    }
}

/// S.M.A.R.T. / NVMe health for one physical drive. Every field is best-effort: Windows hands
/// some of it to standard users (temperature, NVMe health log on most inbox drivers), the rest
/// needs admin and simply stays `None`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DriveHealth {
    pub id: String,
    pub name: String,
    pub bus: String,
    pub media: String,
    pub is_internal: bool,
    /// "Verified", "Failing", or "" when unknown.
    pub smart_status: String,
    pub percentage_used: Option<u8>,
    pub available_spare: Option<u8>,
    pub available_spare_threshold: Option<u8>,
    pub temperature_c: Option<i32>,
    pub bytes_written: Option<u64>,
    pub bytes_read: Option<u64>,
    pub power_on_hours: Option<u64>,
    pub power_cycles: Option<u64>,
    pub unsafe_shutdowns: Option<u64>,
    pub media_errors: Option<u64>,
    pub critical_warning: Option<u8>,
}

impl DriveHealth {
    pub fn life_remaining(&self) -> Option<u8> {
        self.percentage_used.map(|u| 100u8.saturating_sub(u))
    }
    pub fn is_healthy(&self) -> bool {
        self.critical_warning.unwrap_or(0) == 0 && self.smart_status != "Failing"
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DiskStats {
    pub volumes: Vec<Volume>,
    pub read_bps: u64,
    pub write_bps: u64,
    /// Bytes moved since Blip started (Windows exposes no since-boot disk totals to users).
    pub total_read: u64,
    pub total_written: u64,
    /// Active time 0–100 (Task Manager's disk %), where available.
    pub active_pct: Option<f64>,
    pub drives: Vec<DriveHealth>,
}

impl DiskStats {
    pub fn system_volume(&self) -> Option<&Volume> {
        self.volumes.iter().find(|v| v.is_system).or(self.volumes.first())
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GpuStats {
    pub name: String,
    pub utilization: f64,
    pub temperature_c: Option<f64>,
    pub dedicated_used: Option<u64>,
    pub dedicated_total: Option<u64>,
    pub shared_used: Option<u64>,
    /// Per-engine busy % (3D, Copy, Video Decode, Compute…), like Task Manager.
    pub engines: Vec<(String, f64)>,
    pub available: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Interface {
    pub id: String,
    /// "Wi-Fi", "Ethernet", "Tailscale"…
    pub name: String,
    pub description: String,
    pub kind: InterfaceKind,
    pub ipv4: Vec<String>,
    pub ipv6: Vec<String>,
    pub mac: String,
    pub gateway: Option<String>,
    pub dns: Vec<String>,
    pub link_speed_bps: Option<u64>,
    pub is_up: bool,
    pub ssid: Option<String>,
    pub signal_pct: Option<u8>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum InterfaceKind {
    #[default]
    Other,
    Ethernet,
    WiFi,
    Cellular,
    Vpn,
    Loopback,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NetworkStats {
    pub connected: bool,
    pub primary: Option<String>,
    pub down_bps: u64,
    pub up_bps: u64,
    /// Session totals (64-bit counters, loopback excluded).
    pub total_down: u64,
    pub total_up: u64,
    pub ping_ms: Option<f64>,
    pub router_ping_ms: Option<f64>,
    pub router_ip: Option<String>,
    pub interfaces: Vec<Interface>,
    pub vpn: Option<String>,
    /// Windows "metered connection" — automated speed tests skip metered networks.
    pub metered: bool,
}

impl NetworkStats {
    pub fn primary_interface(&self) -> Option<&Interface> {
        let id = self.primary.as_ref()?;
        self.interfaces.iter().find(|i| &i.id == id)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BatteryStats {
    pub present: bool,
    pub level: f64,
    pub charging: bool,
    pub plugged_in: bool,
    pub health_pct: Option<f64>,
    pub cycle_count: Option<u32>,
    pub design_capacity_mwh: Option<u32>,
    pub full_capacity_mwh: Option<u32>,
    pub temperature_c: Option<f64>,
    /// Minutes, when Windows has an estimate.
    pub minutes_remaining: Option<u32>,
    pub rate_mw: Option<i32>,
    pub chemistry: Option<String>,
    pub battery_saver: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Fan {
    pub name: String,
    pub rpm: u32,
    pub min_rpm: Option<u32>,
    pub max_rpm: Option<u32>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ThermalStats {
    pub cpu_c: Option<f64>,
    pub gpu_c: Option<f64>,
    /// ACPI thermal zones (name, °C).
    pub zones: Vec<(String, f64)>,
    pub fans: Vec<Fan>,
    pub level: ThermalLevel,
    /// Whether the CPU is running below its base clock under load (Windows "% Processor
    /// Performance" < 100 with high utilisation) — the honest throttling signal Windows gives
    /// standard users.
    pub throttling: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum ThermalLevel {
    #[default]
    Nominal,
    Fair,
    Serious,
    Critical,
}

impl ThermalLevel {
    pub fn english(self) -> &'static str {
        match self {
            ThermalLevel::Nominal => "Nominal",
            ThermalLevel::Fair => "Fair",
            ThermalLevel::Serious => "Serious",
            ThermalLevel::Critical => "Critical",
        }
    }
    pub fn rank(self) -> i32 {
        self as i32
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ProcessInfo {
    pub pid: u32,
    pub name: String,
    /// % of ONE core summed across cores (Task Manager divides by core count; Blip on the Mac
    /// shows per-core %, and so do we — 200% = two cores busy).
    pub cpu: f64,
    /// Private working set (Task Manager's "Memory" column).
    pub memory: u64,
    pub exe: Option<String>,
    /// Owned by the signed-in user — the only processes Blip offers to end.
    pub user_owned: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SystemInfo {
    pub uptime_secs: u64,
    pub model: String,
    pub manufacturer: String,
    pub os_name: String,
    pub os_version: String,
    pub host_name: String,
    pub blip_memory: u64,
    pub blip_cpu: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Snapshot {
    pub cpu: CpuStats,
    pub memory: MemoryStats,
    pub disk: DiskStats,
    pub gpu: GpuStats,
    pub network: NetworkStats,
    pub battery: BatteryStats,
    pub thermal: ThermalStats,
    pub system: SystemInfo,
    pub top_cpu: Vec<ProcessInfo>,
    pub top_memory: Vec<ProcessInfo>,
    /// Unix seconds.
    pub timestamp: u64,
}

pub fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
