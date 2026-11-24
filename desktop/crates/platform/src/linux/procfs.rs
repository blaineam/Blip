//! /proc: the CPU user/kernel split, memory breakdown, per-disk I/O and pressure stall info.
//! Every file here is world-readable.

use std::collections::HashMap;
use std::path::Path;

pub fn read(path: impl AsRef<Path>) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

pub fn read_trim(path: impl AsRef<Path>) -> Option<String> {
    read(path)
        .map(|s| s.trim_end_matches(['\n', '\0']).trim().to_string())
        .filter(|s| !s.is_empty())
}

pub fn read_u64(path: impl AsRef<Path>) -> Option<u64> {
    read_trim(path)?.parse().ok()
}

pub fn read_i64(path: impl AsRef<Path>) -> Option<i64> {
    read_trim(path)?.parse().ok()
}

/// Aggregate jiffies from the first `cpu` line of /proc/stat.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CpuTimes {
    pub user: u64,
    pub system: u64,
    pub idle: u64,
    pub total: u64,
}

pub fn parse_cpu_times(stat: &str) -> Option<CpuTimes> {
    let line = stat.lines().find(|l| l.starts_with("cpu "))?;
    let v: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    if v.len() < 4 {
        return None;
    }
    let at = |i: usize| v.get(i).copied().unwrap_or(0);
    // user nice system idle iowait irq softirq steal (guest time is already inside user).
    let user = at(0) + at(1);
    let system = at(2) + at(5) + at(6);
    let idle = at(3) + at(4);
    let total = user + system + idle + at(7);
    Some(CpuTimes {
        user,
        system,
        idle,
        total,
    })
}

/// (user %, kernel %) between two readings.
pub fn cpu_split(prev: CpuTimes, now: CpuTimes) -> Option<(f64, f64)> {
    let dt = now.total.checked_sub(prev.total)?;
    if dt == 0 {
        return None;
    }
    let u = now.user.saturating_sub(prev.user) as f64 / dt as f64 * 100.0;
    let s = now.system.saturating_sub(prev.system) as f64 / dt as f64 * 100.0;
    Some((u.clamp(0.0, 100.0), s.clamp(0.0, 100.0)))
}

/// /proc/meminfo in bytes.
pub fn parse_meminfo(text: &str) -> HashMap<String, u64> {
    text.lines()
        .filter_map(|l| {
            let (k, rest) = l.split_once(':')?;
            let mut it = rest.split_whitespace();
            let n: u64 = it.next()?.parse().ok()?;
            let mult = if it.next() == Some("kB") { 1024 } else { 1 };
            Some((k.trim().to_string(), n * mult))
        })
        .collect()
}

/// One whole physical disk's counters from /proc/diskstats.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct DiskCounters {
    pub name: String,
    pub read_bytes: u64,
    pub written_bytes: u64,
    /// Milliseconds the device had I/O in flight.
    pub io_ms: u64,
}

pub fn parse_diskstats(text: &str, keep: impl Fn(&str) -> bool) -> Vec<DiskCounters> {
    text.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() < 13 || !keep(f[2]) {
                return None;
            }
            let n = |i: usize| f[i].parse::<u64>().unwrap_or(0);
            // Sectors are always 512 bytes in this file, whatever the device's block size.
            Some(DiskCounters {
                name: f[2].to_string(),
                read_bytes: n(5) * 512,
                written_bytes: n(9) * 512,
                io_ms: n(12),
            })
        })
        .collect()
}

/// A block device that is real hardware: it has a `device` link (loop, ram, zram, dm and md
/// don't), and isn't an eMMC boot or RPMB area.
pub fn is_physical_disk(name: &str) -> bool {
    !name.contains("boot")
        && !name.contains("rpmb")
        && Path::new("/sys/block").join(name).join("device").exists()
}

/// `avg10` of a /proc/pressure file's `some` and `full` lines.
pub fn parse_psi(text: &str) -> (Option<f64>, Option<f64>) {
    let get = |kind: &str| {
        text.lines()
            .find(|l| l.starts_with(kind))?
            .split_whitespace()
            .find_map(|kv| kv.strip_prefix("avg10="))?
            .parse()
            .ok()
    };
    (get("some"), get("full"))
}

/// The Mac's 0/1/2 pressure scale from memory PSI: share of the last 10 s that tasks spent
/// stalled waiting for memory (reclaim, swap-in).
pub fn psi_level(some: Option<f64>, full: Option<f64>) -> u8 {
    let some = some.unwrap_or(0.0);
    let full = full.unwrap_or(0.0);
    if full >= 20.0 || some >= 60.0 {
        2
    } else if full >= 5.0 || some >= 20.0 {
        1
    } else {
        0
    }
}

/// Compressed bytes held by every zram device (swap on Fedora, SteamOS, Raspberry Pi OS).
pub fn zram_compressed() -> Option<u64> {
    let mut total = None;
    for e in std::fs::read_dir("/sys/block").ok()?.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if !name.starts_with("zram") {
            continue;
        }
        // mm_stat: orig_data_size compr_data_size mem_used_total …
        if let Some(v) = read(e.path().join("mm_stat"))
            .and_then(|s| s.split_whitespace().nth(2).and_then(|x| x.parse::<u64>().ok()))
        {
            *total.get_or_insert(0) += v;
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_split_from_stat() {
        let a = parse_cpu_times("cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 1 2 3 4\n").unwrap();
        let b = parse_cpu_times("cpu  160 0 80 900 50 0 10 0 0 0\n").unwrap();
        let (u, s) = cpu_split(a, b).unwrap();
        assert!((u - 30.0).abs() < 0.01, "{u}");
        assert!((s - 20.0).abs() < 0.01, "{s}");
    }

    #[test]
    fn meminfo_in_bytes() {
        let m = parse_meminfo("MemTotal:       16384 kB\nHugePages_Total:       0\n");
        assert_eq!(m["MemTotal"], 16384 * 1024);
        assert_eq!(m["HugePages_Total"], 0);
    }

    #[test]
    fn diskstats_whole_disks() {
        let text = "   8       0 sda 100 0 2000 50 30 0 4000 20 0 120 70\n 259 0 nvme0n1 1 0 8 0 1 0 8 0 0 5 0 0 0 0\n   7 0 loop0 1 0 2 0 0 0 0 0 0 0 0\n";
        let d = parse_diskstats(text, |n| !n.starts_with("loop"));
        assert_eq!(d.len(), 2);
        assert_eq!(d[0].read_bytes, 2000 * 512);
        assert_eq!(d[0].written_bytes, 4000 * 512);
        assert_eq!(d[0].io_ms, 120);
    }

    #[test]
    fn psi() {
        let t = "some avg10=12.50 avg60=1.00 avg300=0.00 total=1\nfull avg10=6.00 avg60=0 avg300=0 total=0\n";
        assert_eq!(parse_psi(t), (Some(12.5), Some(6.0)));
        assert_eq!(psi_level(Some(12.5), Some(6.0)), 1);
        assert_eq!(psi_level(Some(0.0), Some(0.0)), 0);
        assert_eq!(psi_level(None, Some(30.0)), 2);
    }
}
