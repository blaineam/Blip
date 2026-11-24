//! Network detail on top of sysinfo's counters: interface kind and link speed (/sys/class/net),
//! default route and gateway (/proc/net/route), DNS (systemd-resolved's upstream list or
//! /etc/resolv.conf), and Wi-Fi name, signal, bitrate and the metered flag from
//! NetworkManager — readable by any user, no location prompt (unlike Windows 11 24H2).

use std::path::Path;
use std::time::Instant;

use blip_core::model::{InterfaceKind, NetworkStats};
use zbus::zvariant::OwnedObjectPath;

use super::bus;
use super::procfs::{read, read_i64, read_trim};

const NM: &str = "org.freedesktop.NetworkManager";

#[derive(Debug, Clone, Default)]
struct Wifi {
    iface: String,
    ssid: Option<String>,
    signal: Option<u8>,
    bitrate_kbps: Option<u64>,
}

#[derive(Default)]
pub struct NetInfo {
    wifi: Vec<Wifi>,
    metered: bool,
    at: Option<Instant>,
}

/// Bridges and container plumbing (Docker, libvirt, LXC, Podman) aren't connections.
pub fn is_virtual_plumbing(name: &str) -> bool {
    [
        "veth", "docker", "br-", "virbr", "lxcbr", "lxdbr", "vnet", "cni", "flannel", "podman", "vmnet",
    ]
    .iter()
    .any(|p| name.starts_with(p))
}

pub fn kind_of(name: &str) -> InterfaceKind {
    let sys = Path::new("/sys/class/net").join(name);
    let vpn_prefix = [
        "wg",
        "tun",
        "tap",
        "tailscale",
        "ppp",
        "zt",
        "nordlynx",
        "proton",
        "ipsec",
        "mullvad",
    ]
    .iter()
    .any(|p| name.starts_with(p));
    if name == "lo" {
        InterfaceKind::Loopback
    } else if vpn_prefix || sys.join("tun_flags").exists() {
        InterfaceKind::Vpn
    } else if sys.join("wireless").exists() || sys.join("phy80211").exists() || name.starts_with("wl") {
        InterfaceKind::WiFi
    } else if name.starts_with("wwan") || name.starts_with("rmnet") || name.starts_with("ww") {
        InterfaceKind::Cellular
    } else {
        InterfaceKind::Ethernet
    }
}

/// (interface, gateway, metric) for every default route, lowest metric first.
pub fn default_routes(table: &str) -> Vec<(String, String, u32)> {
    let mut v: Vec<(String, String, u32)> = table
        .lines()
        .skip(1)
        .filter_map(|line| {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() < 7 || f[1] != "00000000" {
                return None;
            }
            let g = u32::from_str_radix(f[2], 16).ok()?;
            let gw = std::net::Ipv4Addr::from(g.to_le_bytes()).to_string();
            Some((f[0].to_string(), gw, f[6].parse().unwrap_or(0)))
        })
        .collect();
    v.sort_by_key(|r| r.2);
    v
}

pub fn dns_servers() -> Vec<String> {
    // The stub resolver (127.0.0.53) hides the real servers; resolved lists them here.
    let text = read("/run/systemd/resolve/resolv.conf").or_else(|| read("/etc/resolv.conf"));
    text.unwrap_or_default()
        .lines()
        .filter_map(|l| l.trim().strip_prefix("nameserver"))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s != "127.0.0.53")
        .collect()
}

impl NetInfo {
    pub fn new() -> Self {
        Self {
            wifi: Vec::new(),
            metered: false,
            at: None,
        }
    }

    pub fn enrich(&mut self, n: &mut NetworkStats) {
        n.interfaces.retain(|i| !is_virtual_plumbing(&i.name));
        if self.at.is_none_or(|t| t.elapsed().as_secs() >= 10) {
            self.refresh_nm();
            self.at = Some(Instant::now());
        }
        let routes = default_routes(&read("/proc/net/route").unwrap_or_default());
        let dns = dns_servers();
        for i in &mut n.interfaces {
            i.kind = kind_of(&i.name);
            let sys = Path::new("/sys/class/net").join(&i.name);
            i.is_up = read_trim(sys.join("operstate")).is_none_or(|s| s == "up" || s == "unknown");
            i.link_speed_bps = read_i64(sys.join("speed"))
                .filter(|s| *s > 0 && *s < 1_000_000)
                .map(|mbps| mbps as u64 * 1_000_000);
            i.gateway = routes.iter().find(|r| r.0 == i.name).map(|r| r.1.clone());
            if i.gateway.is_some() {
                i.dns = dns.clone();
            }
            if let Some(w) = self.wifi.iter().find(|w| w.iface == i.name) {
                i.ssid = w.ssid.clone();
                i.signal_pct = w.signal;
                if let Some(k) = w.bitrate_kbps.filter(|k| *k > 0) {
                    i.link_speed_bps = Some(k * 1000);
                }
            } else if i.kind == InterfaceKind::WiFi {
                i.signal_pct = proc_wireless_signal(&i.name);
            }
            i.description = match i.kind {
                InterfaceKind::WiFi => "Wi-Fi".into(),
                InterfaceKind::Ethernet => "Ethernet".into(),
                InterfaceKind::Vpn => "VPN".into(),
                InterfaceKind::Cellular => "Cellular".into(),
                _ => String::new(),
            };
        }
        // Primary = the non-VPN interface carrying the best default route.
        if let Some(r) = routes.iter().find(|r| {
            n.interfaces
                .iter()
                .any(|i| i.name == r.0 && i.kind != InterfaceKind::Vpn)
        }) {
            n.primary = Some(r.0.clone());
            n.router_ip = Some(r.1.clone());
        }
        n.vpn = n
            .interfaces
            .iter()
            .find(|i| i.kind == InterfaceKind::Vpn && i.is_up)
            .map(|i| i.name.clone());
        n.connected = n.primary.is_some();
        n.metered = self.metered;
    }

    fn refresh_nm(&mut self) {
        self.wifi.clear();
        let Some(c) = bus::system() else { return };
        let Some(nm) = bus::proxy(c, NM, "/org/freedesktop/NetworkManager", NM) else {
            return;
        };
        // NM_METERED_YES = 1, GUESS_YES = 3 (phone hotspots).
        self.metered = matches!(nm.get_property::<u32>("Metered"), Ok(1 | 3));
        let Ok(devices) = nm.call::<_, _, Vec<OwnedObjectPath>>("GetDevices", &()) else {
            return;
        };
        for d in devices {
            let path = bus::path_str(&d);
            let dev = "org.freedesktop.NetworkManager.Device";
            // NM_DEVICE_TYPE_WIFI = 2
            if bus::prop::<u32>(c, NM, &path, dev, "DeviceType") != Some(2) {
                continue;
            }
            let iface = bus::prop::<String>(c, NM, &path, dev, "Interface").unwrap_or_default();
            let wl = "org.freedesktop.NetworkManager.Device.Wireless";
            let mut w = Wifi {
                iface,
                bitrate_kbps: bus::prop::<u32>(c, NM, &path, wl, "Bitrate").map(u64::from),
                ..Default::default()
            };
            if let Some(ap) = bus::prop::<OwnedObjectPath>(c, NM, &path, wl, "ActiveAccessPoint") {
                let ap = bus::path_str(&ap);
                if ap != "/" {
                    let api = "org.freedesktop.NetworkManager.AccessPoint";
                    w.ssid = bus::prop::<Vec<u8>>(c, NM, &ap, api, "Ssid")
                        .map(|b| String::from_utf8_lossy(&b).to_string())
                        .filter(|s| !s.is_empty());
                    w.signal = bus::prop::<u8>(c, NM, &ap, api, "Strength");
                }
            }
            self.wifi.push(w);
        }
    }
}

/// Link quality from /proc/net/wireless (no NetworkManager, e.g. iwd or wpa_supplicant alone).
fn proc_wireless_signal(iface: &str) -> Option<u8> {
    let text = read("/proc/net/wireless")?;
    let line = text
        .lines()
        .find(|l| l.trim_start().starts_with(&format!("{iface}:")))?;
    let q: f64 = line
        .split_whitespace()
        .nth(2)?
        .trim_end_matches('.')
        .parse()
        .ok()?;
    Some((q / 70.0 * 100.0).clamp(0.0, 100.0) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_by_metric() {
        let t = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\nwlan0\t00000000\t0100000A\t0003\t0\t0\t600\t00000000\neth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\neth0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\n";
        let r = default_routes(t);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0], ("eth0".into(), "192.168.1.1".into(), 100));
        assert_eq!(r[1].1, "10.0.0.1");
    }

    #[test]
    fn plumbing_filtered() {
        assert!(is_virtual_plumbing("veth1a2b"));
        assert!(is_virtual_plumbing("docker0"));
        assert!(!is_virtual_plumbing("enp3s0"));
    }
}
