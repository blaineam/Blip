//! GPU: adapters from DXGI (name, dedicated memory, LUID); utilisation per engine and memory in
//! use from the "GPU Engine" / "GPU Adapter Memory" performance counters (exactly what Task
//! Manager reads, no admin); temperature/fan from NVIDIA's NVML when the driver ships it.

use std::collections::HashMap;

use blip_core::model::GpuStats;
use windows::core::{s, w};
use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIFactory1, DXGI_ADAPTER_FLAG_SOFTWARE};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryExW, LOAD_LIBRARY_SEARCH_SYSTEM32};

use super::pdh::Pdh;

#[derive(Clone)]
pub struct Adapter {
    pub name: String,
    pub luid: String,
    pub dedicated: u64,
}

pub fn adapters() -> Vec<Adapter> {
    let mut out = Vec::new();
    // SAFETY: DXGI factory enumeration.
    let Ok(factory) = (unsafe { CreateDXGIFactory1::<IDXGIFactory1>() }) else { return out };
    let mut i = 0;
    while let Ok(a) = unsafe { factory.EnumAdapters1(i) } {
        i += 1;
        let Ok(d) = (unsafe { a.GetDesc1() }) else { continue };
        if d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0 {
            continue;
        }
        let len = d.Description.iter().position(|c| *c == 0).unwrap_or(d.Description.len());
        let name = String::from_utf16_lossy(&d.Description[..len]);
        if name.contains("Microsoft Basic Render") {
            continue;
        }
        let luid = format!("luid_0x{:08x}_0x{:08x}", d.AdapterLuid.HighPart as u32, d.AdapterLuid.LowPart);
        out.push(Adapter { name, luid, dedicated: d.DedicatedVideoMemory as u64 });
    }
    out
}

/// Folds the per-process engine counters into per-adapter, per-engine-type busy %, the way
/// Task Manager does: sum each engine type across processes, the GPU's % is the busiest type.
pub fn fill(out: &mut GpuStats, adapters: &[Adapter], pdh: &Pdh, nvml: Option<&Nvml>) {
    let engines = pdh.array("gpu_engine");
    let mut per: HashMap<(String, String), f64> = HashMap::new();
    for (inst, v) in &engines {
        let lower = inst.to_ascii_lowercase();
        let Some(luid) = extract(&lower, "luid_", 2) else { continue };
        let ty = lower.split("engtype_").nth(1).unwrap_or("other").to_string();
        *per.entry((luid, ty)).or_default() += v;
    }
    // Primary = the adapter with the most dedicated memory (the discrete GPU on hybrids),
    // unless another is far busier right now.
    let busy = |luid: &str| per.iter().filter(|((l, _), _)| l == luid).map(|(_, v)| *v).fold(0.0, f64::max);
    let Some(primary) = adapters
        .iter()
        .max_by(|a, b| (a.dedicated as f64 + busy(&a.luid) * 1e9).total_cmp(&(b.dedicated as f64 + busy(&b.luid) * 1e9)))
    else {
        return;
    };
    out.available = true;
    out.name = primary.name.clone();
    out.dedicated_total = Some(primary.dedicated).filter(|d| *d > 0);
    let mut types: Vec<(String, f64)> =
        per.iter().filter(|((l, _), _)| *l == primary.luid).map(|((_, t), v)| (pretty_engine(t), v.min(100.0))).collect();
    types.sort_by(|a, b| b.1.total_cmp(&a.1));
    out.utilization = types.first().map(|t| t.1).unwrap_or(0.0);
    out.engines = types;
    for (inst, v) in pdh.array("gpu_dedicated") {
        if inst.to_ascii_lowercase().contains(&primary.luid) {
            out.dedicated_used = Some(out.dedicated_used.unwrap_or(0) + v as u64);
        }
    }
    for (inst, v) in pdh.array("gpu_shared") {
        if inst.to_ascii_lowercase().contains(&primary.luid) {
            out.shared_used = Some(out.shared_used.unwrap_or(0) + v as u64);
        }
    }
    if let Some(n) = nvml {
        if primary.name.to_ascii_lowercase().contains("nvidia") {
            out.temperature_c = n.temperature();
        }
    }
}

/// "luid_0x00000000_0x0000d1b4_phys_0…" → "luid_0x00000000_0x0000d1b4".
fn extract(s: &str, key: &str, parts: usize) -> Option<String> {
    let start = s.find(key)?;
    let rest = &s[start..];
    let mut end = 0;
    let mut seen = 0;
    for (i, c) in rest.char_indices() {
        if c == '_' {
            seen += 1;
            if seen > parts {
                end = i;
                break;
            }
        }
        end = i + c.len_utf8();
    }
    Some(rest[..end].to_string())
}

fn pretty_engine(t: &str) -> String {
    match t {
        "3d" => "3D".into(),
        "copy" => "Copy".into(),
        "compute" | "compute_0" | "compute_1" => "Compute".into(),
        "videodecode" => "Video Decode".into(),
        "videoencode" => "Video Encode".into(),
        "videoprocessing" => "Video Processing".into(),
        other => {
            let mut c = other.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        }
    }
}

/// NVIDIA Management Library, loaded from System32 if the NVIDIA driver installed it.
pub struct Nvml {
    get_handle: unsafe extern "C" fn(u32, *mut *mut core::ffi::c_void) -> i32,
    get_temp: unsafe extern "C" fn(*mut core::ffi::c_void, u32, *mut u32) -> i32,
    get_fan: Option<unsafe extern "C" fn(*mut core::ffi::c_void, *mut u32) -> i32>,
}

// Function pointers into a library that's never unloaded.
unsafe impl Send for Nvml {}

impl Nvml {
    pub fn load() -> Option<Self> {
        // SAFETY: System32-only load (no DLL planting), symbols checked before use.
        unsafe {
            let lib = LoadLibraryExW(w!("nvml.dll"), None, LOAD_LIBRARY_SEARCH_SYSTEM32).ok()?;
            type Init = unsafe extern "C" fn() -> i32;
            type Handle = unsafe extern "C" fn(u32, *mut *mut core::ffi::c_void) -> i32;
            type Temp = unsafe extern "C" fn(*mut core::ffi::c_void, u32, *mut u32) -> i32;
            type FanFn = unsafe extern "C" fn(*mut core::ffi::c_void, *mut u32) -> i32;
            type Raw = unsafe extern "system" fn() -> isize;
            let init = std::mem::transmute::<Raw, Init>(GetProcAddress(lib, s!("nvmlInit_v2"))?);
            if init() != 0 {
                return None;
            }
            Some(Self {
                get_handle: std::mem::transmute::<Raw, Handle>(GetProcAddress(lib, s!("nvmlDeviceGetHandleByIndex_v2"))?),
                get_temp: std::mem::transmute::<Raw, Temp>(GetProcAddress(lib, s!("nvmlDeviceGetTemperature"))?),
                get_fan: GetProcAddress(lib, s!("nvmlDeviceGetFanSpeed")).map(|f| std::mem::transmute::<Raw, FanFn>(f)),
            })
        }
    }

    pub fn temperature(&self) -> Option<f64> {
        let mut h = std::ptr::null_mut();
        let mut t = 0u32;
        // SAFETY: NVML calls with out-params; 0 = NVML_TEMPERATURE_GPU.
        unsafe {
            ((self.get_handle)(0, &mut h) == 0 && (self.get_temp)(h, 0, &mut t) == 0).then_some(t as f64)
        }
    }

    /// Fan speed as % of max (NVML doesn't expose RPM on consumer cards).
    pub fn fan_pct(&self) -> Option<u32> {
        let f = self.get_fan?;
        let mut h = std::ptr::null_mut();
        let mut v = 0u32;
        unsafe { ((self.get_handle)(0, &mut h) == 0 && f(h, &mut v) == 0).then_some(v) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_engine_instance() {
        let i = "pid_1234_luid_0x00000000_0x0000d1b4_phys_0_eng_0_engtype_3d";
        assert_eq!(extract(i, "luid_", 2).as_deref(), Some("luid_0x00000000_0x0000d1b4"));
        assert_eq!(pretty_engine("videodecode"), "Video Decode");
    }
}
