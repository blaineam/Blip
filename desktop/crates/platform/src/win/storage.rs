//! Drive health without admin. Physical drives are opened with *no* access rights, which is
//! enough for `IOCTL_STORAGE_QUERY_PROPERTY`: the device descriptor (model, bus), the seek
//! penalty (SSD vs HDD), the drive's own temperature sensors, and — through the inbox NVMe
//! driver's protocol pass-through — the full NVMe SMART/Health log the Mac reads through IOKit.
//! Anything a given driver refuses simply stays unknown.

use blip_core::model::DriveHealth;

use super::dev::{Device, GENERIC_READ};

const IOCTL_STORAGE_QUERY_PROPERTY: u32 = 0x002D_1400;
const IOCTL_STORAGE_PREDICT_FAILURE: u32 = 0x002D_1100;

const STORAGE_DEVICE_PROPERTY: u32 = 0;
const STORAGE_DEVICE_SEEK_PENALTY_PROPERTY: u32 = 7;
const STORAGE_DEVICE_PROTOCOL_SPECIFIC_PROPERTY: u32 = 50;
const STORAGE_DEVICE_TEMPERATURE_PROPERTY: u32 = 56;

const PROTOCOL_TYPE_NVME: u32 = 3;
const NVME_DATA_TYPE_LOG_PAGE: u32 = 2;
const NVME_LOG_PAGE_HEALTH_INFO: u32 = 2;

const BUS_NAMES: &[(u32, &str)] = &[
    (1, "SCSI"), (2, "ATAPI"), (3, "ATA"), (4, "FireWire"), (5, "SSA"), (6, "Fibre"), (7, "USB"),
    (8, "RAID"), (9, "iSCSI"), (10, "SAS"), (11, "SATA"), (12, "SD"), (13, "MMC"), (14, "Virtual"),
    (15, "File-backed"), (16, "Spaces"), (17, "NVMe"), (18, "SCM"), (19, "UFS"),
];

fn query(dev: &Device, property: u32, extra: &[u8], out: &mut [u8]) -> Option<u32> {
    let mut input = Vec::with_capacity(8 + extra.len().max(4));
    input.extend_from_slice(&property.to_le_bytes());
    input.extend_from_slice(&0u32.to_le_bytes()); // PropertyStandardQuery
    if extra.is_empty() {
        input.extend_from_slice(&[0u8; 4]);
    } else {
        input.extend_from_slice(extra);
    }
    dev.ioctl_raw(
        IOCTL_STORAGE_QUERY_PROPERTY,
        Some((input.as_ptr() as _, input.len() as u32)),
        (out.as_mut_ptr() as _, out.len() as u32),
    )
}

fn u32_at(b: &[u8], o: usize) -> u32 {
    b.get(o..o + 4).map(|s| u32::from_le_bytes(s.try_into().unwrap())).unwrap_or(0)
}
fn u64_at(b: &[u8], o: usize) -> u64 {
    b.get(o..o + 8).map(|s| u64::from_le_bytes(s.try_into().unwrap())).unwrap_or(0)
}
fn i16_at(b: &[u8], o: usize) -> i16 {
    b.get(o..o + 2).map(|s| i16::from_le_bytes(s.try_into().unwrap())).unwrap_or(0)
}
fn cstr_at(b: &[u8], o: usize) -> String {
    if o == 0 || o >= b.len() {
        return String::new();
    }
    let end = b[o..].iter().position(|c| *c == 0).map_or(b.len(), |e| o + e);
    String::from_utf8_lossy(&b[o..end]).trim().to_string()
}

pub fn drives() -> Vec<DriveHealth> {
    let mut out = Vec::new();
    let mut misses = 0;
    for n in 0..32 {
        let path = format!("\\\\.\\PhysicalDrive{n}");
        let Some(dev) = Device::open(&path, 0) else {
            misses += 1;
            if misses > 4 {
                break;
            }
            continue;
        };
        misses = 0;
        if let Some(d) = drive(&dev, n) {
            out.push(d);
        }
    }
    out
}

fn drive(dev: &Device, n: u32) -> Option<DriveHealth> {
    let mut buf = vec![0u8; 1024];
    query(dev, STORAGE_DEVICE_PROPERTY, &[], &mut buf)?;
    // STORAGE_DEVICE_DESCRIPTOR
    let removable = buf[10] != 0;
    let vendor = cstr_at(&buf, u32_at(&buf, 12) as usize);
    let product = cstr_at(&buf, u32_at(&buf, 16) as usize);
    let bus_type = u32_at(&buf, 28);
    let bus = BUS_NAMES.iter().find(|(k, _)| *k == bus_type).map_or("Other", |(_, v)| v).to_string();
    if bus_type == 14 || bus_type == 15 || bus_type == 16 {
        return None; // virtual disks, VHDs and Storage Spaces pools have no health of their own
    }
    let mut name = if vendor.is_empty() || product.starts_with(&vendor) { product.clone() } else { format!("{vendor} {product}") };
    if name.is_empty() {
        name = format!("Disk {n}");
    }

    let mut seek = [0u8; 12];
    let media = match query(dev, STORAGE_DEVICE_SEEK_PENALTY_PROPERTY, &[], &mut seek) {
        Some(_) if seek[8] == 0 => "SSD",
        Some(_) => "HDD",
        None => "",
    };

    let mut d = DriveHealth {
        id: n.to_string(),
        name,
        bus: bus.clone(),
        media: media.into(),
        is_internal: !removable && bus_type != 7,
        ..Default::default()
    };

    // Drive temperature sensors (works for NVMe and most SATA SSDs on Windows 10+).
    let mut t = vec![0u8; 256];
    if query(dev, STORAGE_DEVICE_TEMPERATURE_PROPERTY, &[], &mut t).is_some() {
        let count = u16::from_le_bytes([t[12], t[13]]) as usize;
        // TemperatureInfo[] starts at 24; each entry 16 bytes, Temperature at +2 (°C).
        let temps: Vec<i16> = (0..count.min(8)).map(|i| i16_at(&t, 24 + i * 16 + 2)).filter(|c| (-40..150).contains(c)).collect();
        if let Some(max) = temps.iter().max() {
            d.temperature_c = Some(*max as i32);
        }
    }

    if bus_type == 17 {
        nvme_health(dev, &mut d);
        if d.percentage_used.is_none() {
            // Some drivers want read access for pass-through; that open fails without admin.
            if let Some(rd) = Device::open(&format!("\\\\.\\PhysicalDrive{n}"), GENERIC_READ) {
                nvme_health(&rd, &mut d);
            }
        }
    } else {
        // ATA/SCSI: SMART prediction is the one bit Windows hands out cheaply.
        let mut pf = vec![0u8; 516];
        if dev.ioctl_raw(IOCTL_STORAGE_PREDICT_FAILURE, None, (pf.as_mut_ptr() as _, pf.len() as u32)).is_some() {
            d.smart_status = if u32_at(&pf, 0) != 0 { "Failing".into() } else { "Verified".into() };
        }
    }
    Some(d)
}

fn nvme_health(dev: &Device, d: &mut DriveHealth) {
    // STORAGE_PROTOCOL_SPECIFIC_DATA (40 bytes) follows the 8-byte query header.
    let mut spec = [0u32; 10];
    spec[0] = PROTOCOL_TYPE_NVME;
    spec[1] = NVME_DATA_TYPE_LOG_PAGE;
    spec[2] = NVME_LOG_PAGE_HEALTH_INFO;
    spec[3] = 0xFFFF_FFFF; // all namespaces
    spec[4] = 40; // ProtocolDataOffset (from the start of this struct)
    spec[5] = 512; // ProtocolDataLength
    let mut extra: Vec<u8> = spec.iter().flat_map(|v| v.to_le_bytes()).collect();
    extra.extend_from_slice(&[0u8; 512]);
    let mut out = vec![0u8; 8 + 40 + 512];
    if query(dev, STORAGE_DEVICE_PROTOCOL_SPECIFIC_PROPERTY, &extra, &mut out).is_none() {
        return;
    }
    // STORAGE_PROTOCOL_DATA_DESCRIPTOR: Version, Size, then the 40-byte spec echo.
    let data_offset = u32_at(&out, 8 + 16) as usize;
    let start = 8 + data_offset;
    let Some(log) = out.get(start..start + 512) else { return };
    if let Some(h) = decode_nvme_health(log) {
        d.critical_warning = Some(h.critical_warning);
        if h.temperature_c.is_some() && d.temperature_c.is_none() {
            d.temperature_c = h.temperature_c;
        }
        d.available_spare = Some(h.available_spare);
        d.available_spare_threshold = Some(h.spare_threshold);
        d.percentage_used = Some(h.percentage_used);
        d.bytes_read = Some(h.data_units_read.saturating_mul(512_000));
        d.bytes_written = Some(h.data_units_written.saturating_mul(512_000));
        d.power_cycles = Some(h.power_cycles);
        d.power_on_hours = Some(h.power_on_hours);
        d.unsafe_shutdowns = Some(h.unsafe_shutdowns);
        d.media_errors = Some(h.media_errors);
        d.smart_status = if h.critical_warning == 0 { "Verified".into() } else { "Failing".into() };
    }
}

pub struct NvmeHealth {
    pub critical_warning: u8,
    pub temperature_c: Option<i32>,
    pub available_spare: u8,
    pub spare_threshold: u8,
    pub percentage_used: u8,
    pub data_units_read: u64,
    pub data_units_written: u64,
    pub power_cycles: u64,
    pub power_on_hours: u64,
    pub unsafe_shutdowns: u64,
    pub media_errors: u64,
}

/// NVMe SMART/Health Information log (page 02h) — same offsets as the Mac's `SMARTDecoding`.
pub fn decode_nvme_health(log: &[u8]) -> Option<NvmeHealth> {
    if log.len() < 176 || log.iter().all(|b| *b == 0) {
        return None;
    }
    let kelvin = u16::from_le_bytes([log[1], log[2]]) as i32;
    Some(NvmeHealth {
        critical_warning: log[0],
        temperature_c: (kelvin > 200).then_some(kelvin - 273),
        available_spare: log[3],
        spare_threshold: log[4],
        percentage_used: log[5],
        data_units_read: u64_at(log, 32),
        data_units_written: u64_at(log, 48),
        power_cycles: u64_at(log, 112),
        power_on_hours: u64_at(log, 128),
        unsafe_shutdowns: u64_at(log, 144),
        media_errors: u64_at(log, 160),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_health_log() {
        let mut log = vec![0u8; 512];
        log[1..3].copy_from_slice(&(273u16 + 41).to_le_bytes());
        log[3] = 100;
        log[4] = 10;
        log[5] = 3;
        log[48..56].copy_from_slice(&1000u64.to_le_bytes());
        log[128..136].copy_from_slice(&4321u64.to_le_bytes());
        let h = decode_nvme_health(&log).unwrap();
        assert_eq!(h.temperature_c, Some(41));
        assert_eq!(h.percentage_used, 3);
        assert_eq!(h.data_units_written * 512_000, 512_000_000);
        assert_eq!(h.power_on_hours, 4321);
        assert!(decode_nvme_health(&[0u8; 512]).is_none());
    }
}
