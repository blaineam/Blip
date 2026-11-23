//! Battery: charge/AC state from `GetSystemPowerStatus`; wear (design vs full-charge capacity),
//! cycle count, chemistry, temperature and discharge rate from the battery device's IOCTLs —
//! the same data `powercfg /batteryreport` uses, readable by standard users.

use blip_core::model::BatteryStats;
use windows::core::GUID;
use windows::Win32::Devices::DeviceAndDriverInstallation::*;
use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};

use super::dev::{Device, GENERIC_READ, GENERIC_WRITE};

const GUID_DEVCLASS_BATTERY: GUID = GUID::from_u128(0x72631e54_78a4_11d0_bcf7_00aa00b7b32a);
const IOCTL_BATTERY_QUERY_TAG: u32 = 0x0029_4040;
const IOCTL_BATTERY_QUERY_INFORMATION: u32 = 0x0029_4044;
const IOCTL_BATTERY_QUERY_STATUS: u32 = 0x0029_404C;
const BATTERY_INFORMATION_LEVEL: u32 = 0;
const BATTERY_TEMPERATURE_LEVEL: u32 = 2;
const BATTERY_ESTIMATED_TIME_LEVEL: u32 = 3;

#[repr(C)]
#[derive(Default)]
struct BatteryQueryInformation {
    tag: u32,
    level: u32,
    at_rate: i32,
}

#[repr(C)]
#[derive(Default)]
struct BatteryInformation {
    capabilities: u32,
    technology: u8,
    reserved: [u8; 3],
    chemistry: [u8; 4],
    designed_capacity: u32,
    full_charged_capacity: u32,
    default_alert1: u32,
    default_alert2: u32,
    critical_bias: u32,
    cycle_count: u32,
}

#[repr(C)]
#[derive(Default)]
struct BatteryWaitStatus {
    tag: u32,
    timeout: u32,
    power_state: u32,
    low_capacity: u32,
    high_capacity: u32,
}

#[repr(C)]
#[derive(Default)]
struct BatteryStatus {
    power_state: u32,
    capacity: u32,
    voltage: u32,
    rate: i32,
}

const BATTERY_UNKNOWN_RATE: i32 = i32::MIN;

pub fn sample(out: &mut BatteryStats) {
    let mut ps = SYSTEM_POWER_STATUS::default();
    // SAFETY: out-pointer to a local.
    if unsafe { GetSystemPowerStatus(&mut ps) }.is_err() {
        return;
    }
    // BatteryFlag 128 = no system battery; 255 = unknown.
    out.present = ps.BatteryFlag & 128 == 0 && ps.BatteryFlag != 255 && ps.BatteryLifePercent <= 100;
    if !out.present {
        return;
    }
    out.level = ps.BatteryLifePercent as f64;
    out.plugged_in = ps.ACLineStatus == 1;
    out.charging = ps.BatteryFlag & 8 != 0;
    out.battery_saver = ps.SystemStatusFlag & 1 != 0;
    if ps.BatteryLifeTime != u32::MAX && !out.plugged_in {
        out.minutes_remaining = Some(ps.BatteryLifeTime / 60);
    }
    if let Some(dev) = first_battery() {
        details(&dev, out);
    }
}

fn first_battery() -> Option<Device> {
    // SAFETY: standard SetupAPI enumeration; the list is destroyed before returning.
    unsafe {
        let set = SetupDiGetClassDevsW(Some(&GUID_DEVCLASS_BATTERY), None, None, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE).ok()?;
        let mut result = None;
        for index in 0..4 {
            let mut iface = SP_DEVICE_INTERFACE_DATA { cbSize: std::mem::size_of::<SP_DEVICE_INTERFACE_DATA>() as u32, ..Default::default() };
            if SetupDiEnumDeviceInterfaces(set, None, &GUID_DEVCLASS_BATTERY, index, &mut iface).is_err() {
                break;
            }
            let mut need = 0u32;
            let _ = SetupDiGetDeviceInterfaceDetailW(set, &iface, None, 0, Some(&mut need), None);
            if need == 0 {
                continue;
            }
            let mut buf = vec![0u64; (need as usize).div_ceil(8)];
            let detail = buf.as_mut_ptr() as *mut SP_DEVICE_INTERFACE_DETAIL_DATA_W;
            (*detail).cbSize = std::mem::size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32;
            if SetupDiGetDeviceInterfaceDetailW(set, &iface, Some(detail), need, None, None).is_err() {
                continue;
            }
            let path_ptr = std::ptr::addr_of!((*detail).DevicePath) as *const u16;
            let mut len = 0;
            while *path_ptr.add(len) != 0 {
                len += 1;
            }
            let path = String::from_utf16_lossy(std::slice::from_raw_parts(path_ptr, len));
            if let Some(d) = Device::open(&path, GENERIC_READ | GENERIC_WRITE).or_else(|| Device::open(&path, GENERIC_READ)) {
                result = Some(d);
                break;
            }
        }
        let _ = SetupDiDestroyDeviceInfoList(set);
        result
    }
}

fn details(dev: &Device, out: &mut BatteryStats) {
    let wait: u32 = 0;
    let mut tag: u32 = 0;
    if dev.ioctl(IOCTL_BATTERY_QUERY_TAG, Some(&wait), &mut tag).is_none() || tag == 0 {
        return;
    }
    let mut info = BatteryInformation::default();
    let q = BatteryQueryInformation { tag, level: BATTERY_INFORMATION_LEVEL, at_rate: 0 };
    if dev.ioctl(IOCTL_BATTERY_QUERY_INFORMATION, Some(&q), &mut info).is_some() {
        if info.designed_capacity > 0 && info.full_charged_capacity > 0 && info.designed_capacity != u32::MAX {
            out.design_capacity_mwh = Some(info.designed_capacity);
            out.full_capacity_mwh = Some(info.full_charged_capacity);
            out.health_pct = Some((info.full_charged_capacity as f64 / info.designed_capacity as f64 * 100.0).min(100.0));
        }
        if info.cycle_count > 0 {
            out.cycle_count = Some(info.cycle_count);
        }
        let chem = String::from_utf8_lossy(&info.chemistry).trim_matches(char::from(0)).trim().to_string();
        if !chem.is_empty() {
            out.chemistry = Some(chem);
        }
    }
    let mut tenths_kelvin: u32 = 0;
    let q = BatteryQueryInformation { tag, level: BATTERY_TEMPERATURE_LEVEL, at_rate: 0 };
    if dev.ioctl(IOCTL_BATTERY_QUERY_INFORMATION, Some(&q), &mut tenths_kelvin).is_some() && tenths_kelvin > 2000 {
        out.temperature_c = Some(tenths_kelvin as f64 / 10.0 - 273.15);
    }
    if out.minutes_remaining.is_none() && !out.plugged_in {
        let mut secs: u32 = 0;
        let q = BatteryQueryInformation { tag, level: BATTERY_ESTIMATED_TIME_LEVEL, at_rate: 0 };
        if dev.ioctl(IOCTL_BATTERY_QUERY_INFORMATION, Some(&q), &mut secs).is_some() && secs != u32::MAX && secs > 0 {
            out.minutes_remaining = Some(secs / 60);
        }
    }
    let ws = BatteryWaitStatus { tag, ..Default::default() };
    let mut st = BatteryStatus::default();
    if dev.ioctl(IOCTL_BATTERY_QUERY_STATUS, Some(&ws), &mut st).is_some() && st.rate != BATTERY_UNKNOWN_RATE {
        out.rate_mw = Some(st.rate);
        if st.power_state & 0x4 != 0 {
            out.charging = true;
        }
    }
}
