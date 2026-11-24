//! GPU load without root, per driver:
//! - amdgpu: `gpu_busy_percent`, VRAM and GTT use, edge temperature (sysfs).
//! - i915 / xe: busy = 1 − RC6 (idle) residency growth, the same signal `intel_gpu_top` shows as
//!   "RC6"; engine counters need perf privileges, RC6 doesn't.
//! - v3d (Raspberry Pi 4/5): `gpu_stats`, cumulative busy nanoseconds per queue — Blip's
//!   per-engine view.
//! - NVIDIA proprietary: NVML from the driver (`libnvidia-ml.so.1`), like Windows.

use std::path::{Path, PathBuf};
use std::time::Instant;

use blip_core::model::GpuStats;

use super::procfs::{read, read_trim, read_u64};

#[derive(Debug, Clone)]
struct Card {
    dev: PathBuf,
    driver: String,
    name: String,
}

pub struct GpuSampler {
    card: Option<Card>,
    nvml: Option<Nvml>,
    rc6: Option<(u64, Instant)>,
    v3d: Vec<(String, u64, u64)>,
}

impl Default for GpuSampler {
    fn default() -> Self {
        Self::new()
    }
}

impl GpuSampler {
    pub fn new() -> Self {
        let cards = cards();
        let nvml = Nvml::load();
        // Prefer the discrete GPU: NVIDIA (NVML), then amdgpu with the most VRAM, then the rest.
        let card = cards
            .iter()
            .max_by_key(|c| {
                let vram = read_u64(c.dev.join("mem_info_vram_total")).unwrap_or(0);
                let rank = match c.driver.as_str() {
                    "nvidia" => 3,
                    "amdgpu" if vram > (2 << 30) => 2,
                    "amdgpu" | "i915" | "xe" | "v3d" => 1,
                    _ => 0,
                };
                (rank, vram)
            })
            .cloned();
        Self {
            card,
            nvml,
            rc6: None,
            v3d: Vec::new(),
        }
    }

    /// NVIDIA fan speed as % of max (NVML doesn't expose RPM on consumer cards).
    pub fn fan_pct(&self) -> Option<u32> {
        self.nvml.as_ref()?.fan_pct()
    }

    pub fn sample(&mut self, out: &mut GpuStats, hwmon_gpu_c: Option<f64>) {
        if let Some(n) = &self.nvml {
            if let Some(name) = n.name() {
                out.available = true;
                out.name = name;
                out.utilization = n.utilization().unwrap_or(0.0);
                out.temperature_c = n.temperature();
                if let Some((used, total)) = n.memory() {
                    out.dedicated_used = Some(used);
                    out.dedicated_total = Some(total);
                }
                return;
            }
        }
        let Some(card) = self.card.clone() else {
            return;
        };
        out.available = true;
        out.name = card.name.clone();
        out.temperature_c = hwmon_gpu_c.or_else(|| hwmon_temp(&card.dev));
        match card.driver.as_str() {
            "amdgpu" | "radeon" => {
                if let Some(b) = read_u64(card.dev.join("gpu_busy_percent")) {
                    out.utilization = b.min(100) as f64;
                }
                out.dedicated_used = read_u64(card.dev.join("mem_info_vram_used"));
                out.dedicated_total = read_u64(card.dev.join("mem_info_vram_total"));
                out.shared_used = read_u64(card.dev.join("mem_info_gtt_used"));
            }
            "i915" | "xe" => {
                if let Some(ms) = rc6_ms(&card.dev) {
                    let now = Instant::now();
                    if let Some((prev, at)) = self.rc6 {
                        let wall = now.duration_since(at).as_secs_f64() * 1000.0;
                        if wall > 0.0 {
                            let idle = ms.saturating_sub(prev) as f64 / wall;
                            out.utilization = ((1.0 - idle) * 100.0).clamp(0.0, 100.0);
                        }
                    }
                    self.rc6 = Some((ms, now));
                }
            }
            "v3d" => {
                let now = v3d_stats(&card.dev);
                let mut busiest: f64 = 0.0;
                for (queue, ts, busy) in &now {
                    if let Some((_, pts, pbusy)) = self.v3d.iter().find(|(q, _, _)| q == queue) {
                        let wall = ts.saturating_sub(*pts) as f64;
                        if wall > 0.0 {
                            let pct = (busy.saturating_sub(*pbusy) as f64 / wall * 100.0).clamp(0.0, 100.0);
                            busiest = busiest.max(pct);
                            out.engines.push((v3d_queue_name(queue), pct));
                        }
                    }
                }
                out.utilization = busiest;
                self.v3d = now;
            }
            _ => {}
        }
    }
}

fn cards() -> Vec<Card> {
    let mut v = Vec::new();
    let Ok(rd) = std::fs::read_dir("/sys/class/drm") else {
        return v;
    };
    let mut names: Vec<String> = rd
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n.starts_with("card") && n[4..].chars().all(|c| c.is_ascii_digit()) && n.len() > 4)
        .collect();
    names.sort();
    for n in names {
        let dev = Path::new("/sys/class/drm").join(&n).join("device");
        let driver = std::fs::read_link(dev.join("driver"))
            .ok()
            .and_then(|p| p.file_name().map(|f| f.to_string_lossy().to_string()))
            .unwrap_or_default();
        // vc4 is the Pi's display controller; its render GPU is the separate v3d card.
        if driver.is_empty() || driver == "vc4" || driver == "simpledrm" {
            continue;
        }
        let name = pci_name(&dev).unwrap_or_else(|| match driver.as_str() {
            "v3d" => pi_gpu_name(),
            "i915" | "xe" => "Intel Graphics".into(),
            "amdgpu" => "AMD Radeon Graphics".into(),
            "nouveau" | "nvidia" => "NVIDIA GPU".into(),
            "panfrost" | "panthor" => "Arm Mali".into(),
            "msm" => "Qualcomm Adreno".into(),
            other => other.to_string(),
        });
        v.push(Card { dev, driver, name });
    }
    v
}

fn pi_gpu_name() -> String {
    let model = read_trim("/proc/device-tree/model").unwrap_or_default();
    if model.contains("Raspberry Pi 5") || model.contains("Raspberry Pi 500") {
        "Broadcom VideoCore VII".into()
    } else {
        "Broadcom VideoCore VI".into()
    }
}

/// Marketing name from the PCI ID database every distro ships (hwdata / pciutils).
fn pci_name(dev: &Path) -> Option<String> {
    let hex = |f: &str| read_trim(dev.join(f)).map(|s| s.trim_start_matches("0x").to_ascii_lowercase());
    let vendor = hex("vendor")?;
    let device = hex("device")?;
    let db = [
        "/usr/share/hwdata/pci.ids",
        "/usr/share/misc/pci.ids",
        "/usr/share/pci.ids",
    ]
    .iter()
    .find_map(read)?;
    lookup_pci(&db, &vendor, &device)
}

pub fn lookup_pci(db: &str, vendor: &str, device: &str) -> Option<String> {
    let mut vendor_name = None;
    for line in db.lines() {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        if !line.starts_with('\t') {
            if vendor_name.is_some() {
                break;
            }
            if line.len() > 6 && line[..4].eq_ignore_ascii_case(vendor) {
                vendor_name = Some(line[4..].trim().to_string());
            }
        } else if vendor_name.is_some() && !line.starts_with("\t\t") {
            let l = line.trim_start();
            if l.len() > 6 && l[..4].eq_ignore_ascii_case(device) {
                let model = l[4..].trim();
                // "Navi 31 [Radeon RX 7900 XT/7900 XTX]" → the bracketed retail name.
                let model = match (model.find('['), model.rfind(']')) {
                    (Some(a), Some(b)) if b > a => &model[a + 1..b],
                    _ => model,
                };
                let vendor = short_vendor(vendor_name.as_deref().unwrap_or(""));
                return Some(if model.starts_with(vendor) {
                    model.to_string()
                } else {
                    format!("{vendor} {model}")
                });
            }
        }
    }
    None
}

fn short_vendor(v: &str) -> &str {
    if v.contains("NVIDIA") {
        "NVIDIA"
    } else if v.contains("AMD") || v.contains("ATI") {
        "AMD"
    } else if v.contains("Intel") {
        "Intel"
    } else {
        v.split_whitespace().next().unwrap_or(v)
    }
}

fn hwmon_temp(dev: &Path) -> Option<f64> {
    let rd = std::fs::read_dir(dev.join("hwmon")).ok()?;
    rd.flatten()
        .find_map(|e| read_u64(e.path().join("temp1_input")))
        .map(|m| m as f64 / 1000.0)
}

/// Milliseconds the GPU has spent in RC6 (fully idle) since boot.
fn rc6_ms(dev: &Path) -> Option<u64> {
    let drm = dev.parent()?;
    [
        drm.join("gt/gt0/rc6_residency_ms"),
        drm.join("power/rc6_residency_ms"),
        dev.join("tile0/gt0/gtidle/idle_residency_ms"),
    ]
    .iter()
    .find_map(read_u64)
}

/// (queue, timestamp ns, busy ns) per V3D queue.
fn v3d_stats(dev: &Path) -> Vec<(String, u64, u64)> {
    let Some(text) = read(dev.join("gpu_stats")) else {
        return Vec::new();
    };
    parse_v3d(&text)
}

pub fn parse_v3d(text: &str) -> Vec<(String, u64, u64)> {
    text.lines()
        .skip(1)
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() < 4 {
                return None;
            }
            Some((f[0].to_string(), f[1].parse().ok()?, f[3].parse().ok()?))
        })
        .collect()
}

fn v3d_queue_name(q: &str) -> String {
    match q {
        "bin" => "Binning".into(),
        "render" => "3D".into(),
        "tfu" => "Texture".into(),
        "csd" => "Compute".into(),
        "cache_clean" => "Cache".into(),
        other => other.to_string(),
    }
}

/// NVIDIA Management Library from the proprietary driver.
pub struct Nvml {
    handle: *mut core::ffi::c_void,
    get_name: unsafe extern "C" fn(*mut core::ffi::c_void, *mut u8, u32) -> i32,
    get_temp: unsafe extern "C" fn(*mut core::ffi::c_void, u32, *mut u32) -> i32,
    get_util: unsafe extern "C" fn(*mut core::ffi::c_void, *mut [u32; 2]) -> i32,
    get_mem: unsafe extern "C" fn(*mut core::ffi::c_void, *mut [u64; 3]) -> i32,
    get_fan: Option<unsafe extern "C" fn(*mut core::ffi::c_void, *mut u32) -> i32>,
}

// The device handle and function pointers belong to a library that's never unloaded.
unsafe impl Send for Nvml {}

impl Nvml {
    pub fn load() -> Option<Self> {
        // SAFETY: dlopen of the driver's own library; every symbol is checked before use.
        unsafe {
            let lib = libc::dlopen(c"libnvidia-ml.so.1".as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL);
            if lib.is_null() {
                return None;
            }
            let sym = |n: &std::ffi::CStr| {
                let p = libc::dlsym(lib, n.as_ptr());
                (!p.is_null()).then_some(p)
            };
            type Init = unsafe extern "C" fn() -> i32;
            type Handle = unsafe extern "C" fn(u32, *mut *mut core::ffi::c_void) -> i32;
            let init = std::mem::transmute::<*mut libc::c_void, Init>(sym(c"nvmlInit_v2")?);
            if init() != 0 {
                return None;
            }
            let get_handle =
                std::mem::transmute::<*mut libc::c_void, Handle>(sym(c"nvmlDeviceGetHandleByIndex_v2")?);
            let mut handle = std::ptr::null_mut();
            if get_handle(0, &mut handle) != 0 {
                return None;
            }
            type NameFn = unsafe extern "C" fn(*mut core::ffi::c_void, *mut u8, u32) -> i32;
            type TempFn = unsafe extern "C" fn(*mut core::ffi::c_void, u32, *mut u32) -> i32;
            type UtilFn = unsafe extern "C" fn(*mut core::ffi::c_void, *mut [u32; 2]) -> i32;
            type MemFn = unsafe extern "C" fn(*mut core::ffi::c_void, *mut [u64; 3]) -> i32;
            type FanFn = unsafe extern "C" fn(*mut core::ffi::c_void, *mut u32) -> i32;
            type Raw = *mut libc::c_void;
            Some(Self {
                handle,
                get_name: std::mem::transmute::<Raw, NameFn>(sym(c"nvmlDeviceGetName")?),
                get_temp: std::mem::transmute::<Raw, TempFn>(sym(c"nvmlDeviceGetTemperature")?),
                get_util: std::mem::transmute::<Raw, UtilFn>(sym(c"nvmlDeviceGetUtilizationRates")?),
                get_mem: std::mem::transmute::<Raw, MemFn>(sym(c"nvmlDeviceGetMemoryInfo")?),
                get_fan: sym(c"nvmlDeviceGetFanSpeed").map(|f| std::mem::transmute::<Raw, FanFn>(f)),
            })
        }
    }

    pub fn name(&self) -> Option<String> {
        let mut buf = [0u8; 96];
        // SAFETY: NVML writes a NUL-terminated name of at most `len` bytes.
        if unsafe { (self.get_name)(self.handle, buf.as_mut_ptr(), buf.len() as u32) } != 0 {
            return None;
        }
        let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
        Some(String::from_utf8_lossy(&buf[..end]).trim().to_string()).filter(|s| !s.is_empty())
    }

    pub fn temperature(&self) -> Option<f64> {
        let mut t = 0u32;
        // SAFETY: out-param; 0 = NVML_TEMPERATURE_GPU.
        (unsafe { (self.get_temp)(self.handle, 0, &mut t) } == 0).then_some(t as f64)
    }

    pub fn utilization(&self) -> Option<f64> {
        let mut u = [0u32; 2];
        // SAFETY: nvmlUtilization_t is { gpu, memory } as two u32.
        (unsafe { (self.get_util)(self.handle, &mut u) } == 0).then_some(u[0] as f64)
    }

    /// (used, total) bytes of VRAM.
    pub fn memory(&self) -> Option<(u64, u64)> {
        let mut m = [0u64; 3];
        // SAFETY: nvmlMemory_t is { total, free, used } as three u64.
        (unsafe { (self.get_mem)(self.handle, &mut m) } == 0).then_some((m[2], m[0]))
    }

    pub fn fan_pct(&self) -> Option<u32> {
        let f = self.get_fan?;
        let mut v = 0u32;
        // SAFETY: out-param.
        (unsafe { f(self.handle, &mut v) } == 0).then_some(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pci_lookup() {
        let db = "# c\n1002  Advanced Micro Devices, Inc. [AMD/ATI]\n\t744c  Navi 31 [Radeon RX 7900 XT/7900 XTX/7900 GRE/7900M]\n\t\t1002 0e3b  sub\n8086  Intel Corporation\n\ta7a0  Raptor Lake-P [Iris Xe Graphics]\n";
        assert_eq!(
            lookup_pci(db, "1002", "744c").as_deref(),
            Some("AMD Radeon RX 7900 XT/7900 XTX/7900 GRE/7900M")
        );
        assert_eq!(
            lookup_pci(db, "8086", "a7a0").as_deref(),
            Some("Intel Iris Xe Graphics")
        );
        assert_eq!(lookup_pci(db, "8086", "ffff"), None);
    }

    #[test]
    fn v3d_stats_parse() {
        let t = "queue\ttimestamp\tjobs\truntime\nbin\t1000\t3\t200\nrender\t1000\t3\t500\n";
        let v = parse_v3d(t);
        assert_eq!(v.len(), 2);
        assert_eq!(v[1], ("render".into(), 1000, 500));
    }
}
