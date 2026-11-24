//! The portable sampler: `sysinfo` for CPU, memory, processes and volumes on every OS, with the
//! Windows-native layer (`crate::win`) filling in and overriding where it knows better.

use std::collections::HashMap;
use std::time::Instant;

use blip_core::model::*;
use sysinfo::{Disks, Networks, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind, Users};

use crate::net::Pinger;

pub struct Sampler {
    sys: System,
    disks: Disks,
    #[cfg_attr(windows, allow(dead_code))]
    networks: Networks,
    users: Users,
    self_pid: sysinfo::Pid,
    self_uid: Option<sysinfo::Uid>,
    last: Option<Instant>,
    #[cfg_attr(windows, allow(dead_code))]
    net_totals: HashMap<String, (u64, u64)>,
    #[cfg_attr(not(windows), allow(dead_code))]
    load: LoadAvg,
    pinger: Pinger,
    static_info: SystemInfo,
    cpu_model: String,
    physical: usize,
    disk_totals: (u64, u64),
    #[cfg(windows)]
    win: crate::win::WinSampler,
    #[cfg(target_os = "linux")]
    linux: crate::linux::LinuxSampler,
}

impl Default for Sampler {
    fn default() -> Self {
        Self::new()
    }
}

impl Sampler {
    pub fn new() -> Self {
        let mut sys = System::new().unwrap_or_else(|_| panic!("sysinfo unavailable"));
        sys.refresh_cpu_all();
        let self_pid = sysinfo::get_current_pid().unwrap_or(sysinfo::Pid::from_u32(std::process::id()));
        sys.refresh_processes_specifics(
            ProcessesToUpdate::Some(&[self_pid]),
            true,
            ProcessRefreshKind::nothing().with_user(UpdateKind::Always),
        );
        let self_uid = sys.process(self_pid).and_then(|p| p.user_id().cloned());
        let cpu_model = sys
            .cpus()
            .first()
            .map(|c| c.brand().trim().to_string())
            .unwrap_or_default();
        let static_info = SystemInfo {
            model: sysinfo::Product::name().unwrap_or_default(),
            manufacturer: sysinfo::Product::vendor_name().unwrap_or_default(),
            os_name: System::name().unwrap_or_default(),
            os_version: System::long_os_version().unwrap_or_default(),
            host_name: System::host_name().unwrap_or_default(),
            ..Default::default()
        };
        Self {
            sys,
            disks: Disks::new_with_refreshed_list().unwrap_or_else(|_| Disks::new().expect("disks")),
            networks: Networks::new_with_refreshed_list()
                .unwrap_or_else(|_| Networks::new().expect("networks")),
            users: Users::new_with_refreshed_list().unwrap_or_else(|_| Users::new().expect("users")),
            self_pid,
            self_uid,
            last: None,
            net_totals: HashMap::new(),
            load: LoadAvg::default(),
            pinger: Pinger::start(),
            static_info,
            cpu_model,
            physical: System::physical_core_count().unwrap_or(0),
            disk_totals: (0, 0),
            #[cfg(windows)]
            win: crate::win::WinSampler::new(),
            #[cfg(target_os = "linux")]
            linux: crate::linux::LinuxSampler::new(),
        }
    }

    /// WAN ping target (Settings › Network). Applied on the pinger's next round.
    pub fn set_ping_target(&self, host: &str) {
        self.pinger.set_target(host);
    }

    pub fn sample(&mut self) -> Snapshot {
        let now = Instant::now();
        let dt = self.last.map(|l| (now - l).as_secs_f64()).unwrap_or(0.0);
        self.last = Some(now);

        self.sys.refresh_cpu_usage();
        self.sys.refresh_memory();
        self.sys.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing()
                .with_cpu()
                .with_memory()
                .with_exe(UpdateKind::OnlyIfNotSet)
                .with_user(UpdateKind::OnlyIfNotSet),
        );
        self.disks.refresh(true);

        let mut s = Snapshot {
            timestamp: now_unix(),
            ..Default::default()
        };

        // CPU
        let cores: Vec<f64> = self.sys.cpus().iter().map(|c| c.usage() as f64).collect();
        s.cpu.total = self.sys.global_cpu_usage() as f64;
        s.cpu.cores = cores.clone();
        s.cpu.logical_cores = cores.len();
        s.cpu.physical_cores = self.physical;
        s.cpu.model = self.cpu_model.clone();
        s.cpu.frequency_mhz = self.sys.cpus().first().map(|c| c.frequency()).filter(|f| *f > 0);
        #[cfg(not(windows))]
        {
            let l = System::load_average().unwrap_or(sysinfo::LoadAvg {
                one: 0.0,
                five: 0.0,
                fifteen: 0.0,
            });
            s.cpu.load = Some([l.one, l.five, l.fifteen]);
            s.cpu.user = s.cpu.total;
        }

        // Memory
        s.memory.total = self.sys.total_memory();
        s.memory.available = self.sys.available_memory();
        s.memory.used = s.memory.total.saturating_sub(s.memory.available);
        s.memory.swap_total = self.sys.total_swap();
        s.memory.swap_used = self.sys.used_swap();
        s.memory.committed = s.memory.used + s.memory.swap_used;
        s.memory.commit_limit = s.memory.total + s.memory.swap_total;

        // Volumes
        let sys_root = system_root();
        let mut read_delta = 0u64;
        let mut write_delta = 0u64;
        let mut seen_devices: Vec<String> = Vec::new();
        for d in self.disks.iter() {
            let mount = d.mount_point().display().to_string();
            if d.total_space() == 0 || skip_mount(&mount) || skip_fs(&d.file_system().to_string_lossy()) {
                continue;
            }
            // Bind mounts (SteamOS mounts one partition at /home, /var, /opt, /srv…) are one
            // volume: keep the first, shortest mount of each device.
            let dev = d.name().to_string_lossy().to_string();
            if cfg!(target_os = "linux") && dev.starts_with("/dev/") {
                if seen_devices.contains(&dev) {
                    continue;
                }
                seen_devices.push(dev);
            }
            let u = d.usage();
            read_delta += u.read_bytes;
            write_delta += u.written_bytes;
            let mut name = d.name().to_string_lossy().to_string();
            if name.is_empty() || name.starts_with("/dev/") {
                name = mount.clone();
            }
            s.disk.volumes.push(Volume {
                name,
                mount: mount.clone(),
                file_system: d.file_system().to_string_lossy().to_string(),
                total: d.total_space(),
                free: d.available_space(),
                removable: d.is_removable(),
                is_system: mount.eq_ignore_ascii_case(&sys_root),
            });
        }
        s.disk
            .volumes
            .sort_by_key(|v| (!v.is_system, v.removable, v.mount.clone()));
        if dt > 0.0 {
            s.disk.read_bps = (read_delta as f64 / dt) as u64;
            s.disk.write_bps = (write_delta as f64 / dt) as u64;
            self.disk_totals.0 += read_delta;
            self.disk_totals.1 += write_delta;
        }
        s.disk.total_read = self.disk_totals.0;
        s.disk.total_written = self.disk_totals.1;

        // Processes
        let logical = s.cpu.logical_cores.max(1) as f64;
        let mut procs: Vec<ProcessInfo> = self
            .sys
            .processes()
            .values()
            .filter(|p| p.pid().as_u32() != 0)
            .map(|p| ProcessInfo {
                pid: p.pid().as_u32(),
                name: p.name().to_string_lossy().to_string(),
                cpu: (p.cpu_usage() as f64).min(logical * 100.0),
                memory: p.memory(),
                exe: p.exe().map(|e| e.display().to_string()),
                user_owned: match (&self.self_uid, p.user_id()) {
                    (Some(me), Some(them)) => me == them,
                    _ => false,
                },
            })
            .collect();
        if let Some(me) = self.sys.process(self.self_pid) {
            s.system.blip_memory = me.memory();
            s.system.blip_cpu = me.cpu_usage() as f64;
        }
        let _ = &self.users;
        procs.sort_by(|a, b| b.cpu.total_cmp(&a.cpu));
        s.top_cpu = merge_by_name(&procs, 8, |p| p.cpu);
        procs.sort_by_key(|p| std::cmp::Reverse(p.memory));
        s.top_memory = merge_by_name(&procs, 8, |p| p.memory as f64);

        // System
        s.system = SystemInfo {
            uptime_secs: System::uptime().unwrap_or(0),
            blip_memory: s.system.blip_memory,
            blip_cpu: s.system.blip_cpu,
            ..self.static_info.clone()
        };

        // Network (portable path; Windows replaces it with IP Helper below)
        #[cfg(not(windows))]
        {
            self.networks.refresh(true);
            self.portable_network(&mut s, dt);
        }

        #[cfg(windows)]
        self.win.sample(&mut s, dt, &mut self.load);
        #[cfg(target_os = "linux")]
        self.linux.sample(&mut s, dt);

        let (wan, router) = self.pinger.latest();
        s.network.ping_ms = wan;
        s.network.router_ping_ms = router;
        if let Some(gw) = s.network.router_ip.clone() {
            self.pinger.set_router(&gw);
        }
        s.memory.pressure = pressure(&s.memory);
        #[cfg(target_os = "linux")]
        if let Some(p) = crate::linux::LinuxSampler::pressure() {
            s.memory.pressure = s.memory.pressure.max(p);
        }
        s
    }

    #[cfg(not(windows))]
    fn portable_network(&mut self, s: &mut Snapshot, dt: f64) {
        let mut down = 0u64;
        let mut up = 0u64;
        for (os_name, data) in self.networks.iter() {
            let name = &os_name.to_string_lossy().to_string();
            if name.starts_with("lo") {
                continue;
            }
            down += data.received();
            up += data.transmitted();
            let e = self.net_totals.entry(name.clone()).or_default();
            e.0 += data.received();
            e.1 += data.transmitted();
            let (v4, v6): (Vec<_>, Vec<_>) = data
                .ip_networks()
                .iter()
                .map(|n| n.addr)
                .partition(|a| a.is_ipv4());
            if v4.is_empty() && v6.is_empty() {
                continue;
            }
            let kind = if name.starts_with("utun")
                || name.starts_with("wg")
                || name.starts_with("tailscale")
                || name.starts_with("tun")
            {
                InterfaceKind::Vpn
            } else if name.starts_with("wl") {
                InterfaceKind::WiFi
            } else {
                InterfaceKind::Ethernet
            };
            s.network.interfaces.push(Interface {
                id: name.clone(),
                name: name.clone(),
                kind,
                ipv4: v4.iter().map(|a| a.to_string()).collect(),
                ipv6: v6.iter().map(|a| a.to_string()).collect(),
                mac: data.mac_address().to_string(),
                is_up: true,
                ..Default::default()
            });
        }
        if dt > 0.0 {
            s.network.down_bps = (down as f64 / dt) as u64;
            s.network.up_bps = (up as f64 / dt) as u64;
        }
        s.network.total_down = self.net_totals.values().map(|v| v.0).sum();
        s.network.total_up = self.net_totals.values().map(|v| v.1).sum();
        s.network.router_ip = crate::net::default_gateway();
        s.network.primary = s
            .network
            .interfaces
            .iter()
            .find(|i| i.kind != InterfaceKind::Vpn && !i.ipv4.is_empty())
            .map(|i| i.id.clone());
        s.network.vpn = s
            .network
            .interfaces
            .iter()
            .find(|i| i.kind == InterfaceKind::Vpn)
            .map(|i| i.name.clone());
        s.network.connected = s.network.primary.is_some();
    }
}

/// Chrome/Edge/VS Code run as dozens of processes; like Activity Monitor's app view, the top
/// lists fold same-named processes together so "chrome.exe 140%" isn't spread over 30 rows.
fn merge_by_name(sorted: &[ProcessInfo], n: usize, key: impl Fn(&ProcessInfo) -> f64) -> Vec<ProcessInfo> {
    let mut out: Vec<ProcessInfo> = Vec::new();
    for p in sorted.iter().take(400) {
        match out.iter_mut().find(|o| o.name.eq_ignore_ascii_case(&p.name)) {
            Some(o) => {
                o.cpu += p.cpu;
                o.memory += p.memory;
            }
            None => out.push(p.clone()),
        }
    }
    out.sort_by(|a, b| key(b).total_cmp(&key(a)));
    out.truncate(n);
    out
}

fn system_root() -> String {
    #[cfg(windows)]
    {
        let d = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into());
        format!("{d}\\")
    }
    #[cfg(not(windows))]
    {
        "/".into()
    }
}

/// Read-only images and memory-backed filesystems aren't storage the user manages.
fn skip_fs(fs: &str) -> bool {
    matches!(
        fs,
        "squashfs"
            | "overlay"
            | "tmpfs"
            | "devtmpfs"
            | "efivarfs"
            | "ramfs"
            | "erofs"
            | "iso9660"
            | "fuse.portal"
    )
}

fn skip_mount(m: &str) -> bool {
    #[cfg(target_os = "macos")]
    {
        m.starts_with("/System/Volumes/") || m.starts_with("/private/var/vm")
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        m.starts_with("/boot")
            || m.starts_with("/snap/")
            || m.starts_with("/var/snap/")
            || m.starts_with("/efi")
            || m.starts_with("/run")
            || m.starts_with("/var/lib/docker")
    }
    #[cfg(windows)]
    {
        let _ = m;
        false
    }
}

/// Windows has no kernel memory-pressure level; derive the Mac's 0/1/2 scale from what's left
/// of RAM and of the commit limit (running out of either is what makes Windows thrash).
fn pressure(m: &MemoryStats) -> u8 {
    if m.total == 0 {
        return 0;
    }
    let avail = m.available as f64 / m.total as f64;
    let commit = m.commit_pct();
    if avail < 0.05 || commit > 95.0 {
        2
    } else if avail < 0.12 || commit > 85.0 {
        1
    } else {
        0
    }
}

/// Unix-style exponentially-damped load average, fed from Windows' run queue.
#[derive(Default)]
#[cfg_attr(not(windows), allow(dead_code))]
pub struct LoadAvg {
    values: Option<[f64; 3]>,
    started: Option<Instant>,
}

#[cfg_attr(not(windows), allow(dead_code))]
impl LoadAvg {
    pub fn update(&mut self, runnable: f64, dt: f64) -> Option<[f64; 3]> {
        let started = *self.started.get_or_insert_with(Instant::now);
        let v = self.values.get_or_insert([runnable; 3]);
        if dt > 0.0 {
            for (i, period) in [60.0, 300.0, 900.0].iter().enumerate() {
                let decay = (-dt / period).exp();
                v[i] = v[i] * decay + runnable * (1.0 - decay);
            }
        }
        // Only claim a 1-minute average once a minute of samples exists.
        (started.elapsed().as_secs() >= 60).then_some(*v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samples_this_machine() {
        let mut s = Sampler::new();
        s.sample();
        std::thread::sleep(std::time::Duration::from_millis(300));
        let snap = s.sample();
        assert!(snap.cpu.logical_cores > 0);
        assert!(snap.memory.total > 0);
        assert!(!snap.disk.volumes.is_empty());
        assert!(snap.system.uptime_secs > 0);
        assert!(!snap.top_memory.is_empty());
    }

    #[test]
    fn merges_helper_processes() {
        let p = |n: &str, c: f64| ProcessInfo {
            name: n.into(),
            cpu: c,
            ..Default::default()
        };
        let m = merge_by_name(
            &[p("chrome.exe", 30.0), p("code.exe", 25.0), p("chrome.exe", 20.0)],
            5,
            |p| p.cpu,
        );
        assert_eq!(m[0].name, "chrome.exe");
        assert_eq!(m[0].cpu, 50.0);
    }

    #[test]
    fn load_average_converges() {
        let mut l = LoadAvg::default();
        l.update(0.0, 0.0);
        for _ in 0..600 {
            l.update(4.0, 2.0);
        }
        let v = l.values.unwrap();
        assert!((v[0] - 4.0).abs() < 0.01);
        assert!(v[2] > 2.0);
    }
}
