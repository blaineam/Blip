//! Physical drives: identity from /sys/block, temperature from hwmon (`nvme`, `drivetemp`), and
//! S.M.A.R.T. through UDisks2 — the desktop's disk service reads the NVMe health log and ATA
//! attributes as root and publishes them on the system bus, so Blip never needs root itself.
//! (Rocky 8's UDisks 2.9 predates the NVMe interface; there NVMe drives show temperature only.)

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use blip_core::model::DriveHealth;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use super::bus;
use super::procfs::{read_trim, read_u64};

const UDISKS: &str = "org.freedesktop.UDisks2";

pub fn drives(temps: &[(PathBuf, f64)]) -> Vec<DriveHealth> {
    let Ok(rd) = std::fs::read_dir("/sys/block") else {
        return Vec::new();
    };
    let mut names: Vec<String> = rd
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| super::procfs::is_physical_disk(n))
        .collect();
    names.sort();
    names
        .iter()
        .filter_map(|n| {
            let mut d = identify(n)?;
            let dev = std::fs::canonicalize(Path::new("/sys/block").join(n).join("device")).ok();
            d.temperature_c = dev
                .as_ref()
                .and_then(|dev| temps.iter().find(|(p, _)| p == dev))
                .map(|(_, c)| c.round() as i32);
            smart(n, &mut d);
            Some(d)
        })
        .collect()
}

fn identify(name: &str) -> Option<DriveHealth> {
    let base = Path::new("/sys/block").join(name);
    if read_u64(base.join("size")).unwrap_or(0) == 0 {
        return None; // empty card reader slot
    }
    let dev = base.join("device");
    let canonical = std::fs::canonicalize(&dev)
        .unwrap_or_default()
        .display()
        .to_string();
    let usb = canonical.contains("/usb");
    let removable = read_u64(base.join("removable")).unwrap_or(0) == 1;
    let (bus, model) = if name.starts_with("nvme") {
        ("NVMe".to_string(), read_trim(dev.join("model")))
    } else if name.starts_with("mmcblk") {
        let kind = read_trim(dev.join("type")).unwrap_or_else(|| "SD".into());
        let label = if kind == "MMC" { "eMMC" } else { "SD card" };
        (
            label.to_string(),
            read_trim(dev.join("name")).map(|n| format!("{label} {n}")),
        )
    } else {
        let vendor = read_trim(dev.join("vendor")).filter(|v| v != "ATA");
        let model = read_trim(dev.join("model"));
        let bus = if usb {
            "USB"
        } else if canonical.contains("/virtio") {
            "Virtual"
        } else {
            "SATA"
        };
        (
            bus.to_string(),
            match (vendor, model) {
                (Some(v), Some(m)) if !m.starts_with(&v) => Some(format!("{v} {m}")),
                (_, m) => m,
            },
        )
    };
    let rotational = read_u64(base.join("queue/rotational")).unwrap_or(0) == 1;
    let media = if name.starts_with("mmcblk") || bus == "NVMe" || !rotational {
        "SSD"
    } else {
        "HDD"
    };
    Some(DriveHealth {
        id: format!("/dev/{name}"),
        name: model.unwrap_or_else(|| name.to_string()),
        bus: if usb { "USB".into() } else { bus },
        media: media.into(),
        is_internal: !usb && !removable,
        ..Default::default()
    })
}

fn smart(name: &str, d: &mut DriveHealth) {
    let Some(c) = bus::system() else { return };
    let block = format!("/org/freedesktop/UDisks2/block_devices/{name}");
    let Some(drive) =
        bus::prop::<OwnedObjectPath>(c, UDISKS, &block, "org.freedesktop.UDisks2.Block", "Drive")
    else {
        return;
    };
    let drive = bus::path_str(&drive);
    if drive == "/" {
        return;
    }

    // NVMe (UDisks ≥ 2.10).
    let nvme = "org.freedesktop.UDisks2.NVMe.Controller";
    let proxy = bus::proxy(c, UDISKS, &drive, nvme);
    if let Some(p) = proxy {
        if let Ok(hours) = p.get_property::<u64>("SmartPowerOnHours") {
            d.power_on_hours = Some(hours).filter(|h| *h > 0);
            if let Ok(k) = p.get_property::<u16>("SmartTemperature") {
                if k > 0 && d.temperature_c.is_none() {
                    d.temperature_c = Some(k as i32 - 273);
                }
            }
            let warnings = p
                .get_property::<Vec<String>>("SmartCriticalWarning")
                .unwrap_or_default();
            d.critical_warning = Some(if warnings.is_empty() { 0 } else { 1 });
            let opts: HashMap<&str, Value> = HashMap::from([("auth.no_user_interaction", Value::from(true))]);
            if let Ok(attrs) = p.call::<_, _, HashMap<String, OwnedValue>>("SmartGetAttributes", &(opts,)) {
                apply_nvme_attrs(&attrs, d);
            }
            d.smart_status = if d.is_healthy() { "Verified" } else { "Failing" }.into();
            return;
        }
    }

    // ATA.
    let ata = "org.freedesktop.UDisks2.Drive.Ata";
    let proxy = bus::proxy(c, UDISKS, &drive, ata);
    if let Some(p) = proxy {
        if p.get_property::<bool>("SmartEnabled").unwrap_or(false)
            && p.get_property::<u64>("SmartUpdated").unwrap_or(0) > 0
        {
            let failing = p.get_property::<bool>("SmartFailing").unwrap_or(false);
            d.smart_status = if failing { "Failing" } else { "Verified" }.into();
            if let Ok(k) = p.get_property::<f64>("SmartTemperature") {
                if k > 0.0 && d.temperature_c.is_none() {
                    d.temperature_c = Some((k - 273.15).round() as i32);
                }
            }
            if let Ok(secs) = p.get_property::<u64>("SmartPowerOnSeconds") {
                d.power_on_hours = Some(secs / 3600).filter(|h| *h > 0);
            }
        }
    }
}

fn num(attrs: &HashMap<String, OwnedValue>, key: &str) -> Option<u64> {
    let v = attrs.get(key)?;
    u64::try_from(v)
        .ok()
        .or_else(|| u8::try_from(v).ok().map(u64::from))
        .or_else(|| u16::try_from(v).ok().map(u64::from))
        .or_else(|| u32::try_from(v).ok().map(u64::from))
        .or_else(|| i64::try_from(v).ok().map(|x| x.max(0) as u64))
}

pub fn apply_nvme_attrs(attrs: &HashMap<String, OwnedValue>, d: &mut DriveHealth) {
    d.percentage_used = num(attrs, "percent_used").map(|v| v.min(255) as u8);
    d.available_spare = num(attrs, "avail_spare").map(|v| v.min(255) as u8);
    d.available_spare_threshold = num(attrs, "spare_thresh").map(|v| v.min(255) as u8);
    d.bytes_read = num(attrs, "total_data_read");
    d.bytes_written = num(attrs, "total_data_written");
    d.power_cycles = num(attrs, "power_cycles");
    d.unsafe_shutdowns = num(attrs, "unsafe_shutdowns");
    d.media_errors = num(attrs, "media_errors");
}
