//! Network adapters through IP Helper: names, addresses, gateways, DNS and link speed from
//! `GetAdaptersAddresses`; 64-bit byte counters from `GetIfEntry2` (so the Mac's 32-bit wrap
//! problem never arises here); the primary route from `GetBestInterfaceEx`; SSID/signal from
//! the WLAN API; metered state from the WinRT connection profile.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::Instant;

use blip_core::model::{Interface, InterfaceKind, NetworkStats};
use windows::core::GUID;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::NetworkManagement::IpHelper::*;
use windows::Win32::NetworkManagement::Ndis::IfOperStatusUp;
use windows::Win32::NetworkManagement::WiFi::*;
use windows::Win32::Networking::WinSock::{AF_INET, AF_INET6, AF_UNSPEC, SOCKADDR, SOCKADDR_IN};

const IF_TYPE_ETHERNET: u32 = 6;
const IF_TYPE_PPP: u32 = 23;
const IF_TYPE_LOOPBACK: u32 = 24;
const IF_TYPE_PROP_VIRTUAL: u32 = 53;
const IF_TYPE_WIFI: u32 = 71;
const IF_TYPE_TUNNEL: u32 = 131;
const IF_TYPE_WWAN_PP: u32 = 243;
const IF_TYPE_WWAN_PP2: u32 = 244;

pub struct NetSampler {
    prev: HashMap<u32, (u64, u64)>,
    totals: (u64, u64),
    wifi: HashMap<String, (String, u8)>,
    wifi_at: Option<Instant>,
    metered: bool,
    metered_at: Option<Instant>,
}

struct Counters {
    in_octets: u64,
    out_octets: u64,
    hardware: bool,
}

fn if_counters(index: u32) -> Option<Counters> {
    let mut row = MIB_IF_ROW2 { InterfaceIndex: index, ..Default::default() };
    // SAFETY: row is a valid, index-initialised MIB_IF_ROW2.
    let rc = unsafe { GetIfEntry2(&mut row) };
    if rc.0 != 0 {
        return None;
    }
    Some(Counters { in_octets: row.InOctets, out_octets: row.OutOctets, hardware: row.InterfaceAndOperStatusFlags._bitfield & 1 != 0 })
}

/// SOCKADDR → IpAddr.
///
/// # Safety
/// `sa` must be null or point at a valid socket address of the length IP Helper reported.
unsafe fn sockaddr_ip(sa: *const SOCKADDR) -> Option<IpAddr> {
    if sa.is_null() {
        return None;
    }
    let family = unsafe { (*sa).sa_family };
    if family == AF_INET {
        let sin = unsafe { &*(sa as *const SOCKADDR_IN) };
        let raw = unsafe { sin.sin_addr.S_un.S_addr };
        Some(IpAddr::V4(Ipv4Addr::from(raw.to_ne_bytes())))
    } else if family == AF_INET6 {
        // sockaddr_in6: family(2) port(2) flowinfo(4) addr(16)
        let bytes = unsafe { std::slice::from_raw_parts((sa as *const u8).add(8), 16) };
        let mut a = [0u8; 16];
        a.copy_from_slice(bytes);
        Some(IpAddr::V6(Ipv6Addr::from(a)))
    } else {
        None
    }
}

fn wide_ptr(p: windows::core::PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    // SAFETY: IP Helper strings are NUL-terminated and live in its buffer.
    unsafe { p.to_string() }.unwrap_or_default()
}

pub fn is_vpn(description: &str, name: &str, if_type: u32) -> bool {
    let d = format!("{description} {name}").to_ascii_lowercase();
    if_type == IF_TYPE_PPP
        || [
            "tailscale", "wireguard", "openvpn", "tap-windows", "wintun", "zerotier", "anyconnect", "globalprotect",
            "fortinet", "forticlient", "nordlynx", "mullvad", "protonvpn", "expressvpn", "pangp", "juniper", "pulse secure",
            "netextender", "sonicwall", "cloudflare warp", "vpn",
        ]
        .iter()
        .any(|k| d.contains(k))
}

impl NetSampler {
    pub fn new() -> Self {
        Self { prev: HashMap::new(), totals: (0, 0), wifi: HashMap::new(), wifi_at: None, metered: false, metered_at: None }
    }

    pub fn sample(&mut self, out: &mut NetworkStats, dt: f64) {
        let mut size: u32 = 32 * 1024;
        let mut buf: Vec<u64>;
        let flags = GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST;
        loop {
            buf = vec![0u64; (size as usize).div_ceil(8)];
            // SAFETY: buffer of `size` bytes, 8-aligned.
            let rc = unsafe { GetAdaptersAddresses(AF_UNSPEC.0 as u32, flags, None, Some(buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH), &mut size) };
            if rc == 111 {
                // ERROR_BUFFER_OVERFLOW: `size` now holds what's needed.
                continue;
            }
            if rc != 0 {
                return;
            }
            break;
        }

        let best = best_interface();
        self.refresh_wifi();
        self.refresh_metered();

        let (mut down, mut up) = (0u64, 0u64);
        let mut seen = Vec::new();
        let mut p = buf.as_ptr() as *const IP_ADAPTER_ADDRESSES_LH;
        while !p.is_null() {
            // SAFETY: linked list inside `buf`, written by IP Helper.
            let a = unsafe { &*p };
            p = a.Next;
            let index = unsafe { a.Anonymous1.Anonymous.IfIndex };
            if a.IfType == IF_TYPE_LOOPBACK || a.OperStatus != IfOperStatusUp {
                continue;
            }
            let description = wide_ptr(a.Description);
            let friendly = wide_ptr(a.FriendlyName);
            let lower = description.to_ascii_lowercase();
            // Teredo/IP-HTTPS/6to4 pseudo-tunnels and kernel debuggers aren't interesting.
            if a.IfType == IF_TYPE_TUNNEL && !is_vpn(&description, &friendly, a.IfType) {
                continue;
            }
            if lower.contains("kernel debug") || lower.contains("wan miniport") {
                continue;
            }
            let mut ipv4 = Vec::new();
            let mut ipv6 = Vec::new();
            let mut u = a.FirstUnicastAddress;
            while !u.is_null() {
                // SAFETY: list inside buf.
                let ua = unsafe { &*u };
                if let Some(ip) = unsafe { sockaddr_ip(ua.Address.lpSockaddr) } {
                    match ip {
                        IpAddr::V4(v) => ipv4.push(v.to_string()),
                        IpAddr::V6(v) if !v.is_loopback() => ipv6.push(v.to_string()),
                        _ => {}
                    }
                }
                u = ua.Next;
            }
            let mut gateway = None;
            let mut g = a.FirstGatewayAddress;
            while !g.is_null() {
                let ga = unsafe { &*g };
                if let Some(ip) = unsafe { sockaddr_ip(ga.Address.lpSockaddr) } {
                    if ip.is_ipv4() || gateway.is_none() {
                        gateway = Some(ip.to_string());
                    }
                    if ip.is_ipv4() {
                        break;
                    }
                }
                g = ga.Next;
            }
            let mut dns = Vec::new();
            let mut d = a.FirstDnsServerAddress;
            while !d.is_null() {
                let da = unsafe { &*d };
                if let Some(ip) = unsafe { sockaddr_ip(da.Address.lpSockaddr) } {
                    dns.push(ip.to_string());
                }
                d = da.Next;
            }
            let kind = if is_vpn(&description, &friendly, a.IfType) {
                InterfaceKind::Vpn
            } else {
                match a.IfType {
                    IF_TYPE_WIFI => InterfaceKind::WiFi,
                    IF_TYPE_ETHERNET => InterfaceKind::Ethernet,
                    IF_TYPE_WWAN_PP | IF_TYPE_WWAN_PP2 => InterfaceKind::Cellular,
                    IF_TYPE_PROP_VIRTUAL => InterfaceKind::Other,
                    _ => InterfaceKind::Other,
                }
            };
            let mac = a.PhysicalAddress[..(a.PhysicalAddressLength as usize).min(8)]
                .iter()
                .map(|b| format!("{b:02X}"))
                .collect::<Vec<_>>()
                .join(":");
            let guid = {
                // SAFETY: AdapterName is the "{GUID}" ANSI string.
                unsafe { a.AdapterName.to_string() }.unwrap_or_default()
            };
            let (ssid, signal) = self.wifi.get(&guid.to_ascii_lowercase()).cloned().map_or((None, None), |(s, q)| (Some(s), Some(q)));

            if let Some(c) = if_counters(index) {
                let prev = self.prev.insert(index, (c.in_octets, c.out_octets));
                if let Some((pi, po)) = prev {
                    let di = c.in_octets.saturating_sub(pi);
                    let dout = c.out_octets.saturating_sub(po);
                    // Count physical NICs only: VPN and Hyper-V switch traffic already crosses
                    // one, and summing both would double it.
                    if c.hardware && kind != InterfaceKind::Vpn {
                        down += di;
                        up += dout;
                    }
                }
            }
            seen.push(index);
            out.interfaces.push(Interface {
                id: index.to_string(),
                name: friendly,
                description,
                kind,
                ipv4,
                ipv6,
                mac,
                gateway,
                dns,
                link_speed_bps: Some(a.ReceiveLinkSpeed.max(a.TransmitLinkSpeed)).filter(|s| *s > 0 && *s != u64::MAX),
                is_up: true,
                ssid,
                signal_pct: signal,
            });
        }
        self.prev.retain(|k, _| seen.contains(k));
        self.totals.0 += down;
        self.totals.1 += up;
        if dt > 0.0 {
            out.down_bps = (down as f64 / dt) as u64;
            out.up_bps = (up as f64 / dt) as u64;
        }
        out.total_down = self.totals.0;
        out.total_up = self.totals.1;

        // Primary = the route to the internet; prefer its physical sibling for "Interface" when
        // the route is a full-tunnel VPN, but report the VPN either way.
        out.primary = best.map(|b| b.to_string()).filter(|b| out.interfaces.iter().any(|i| &i.id == b));
        if out.primary.is_none() {
            out.primary = out.interfaces.iter().find(|i| i.gateway.is_some()).map(|i| i.id.clone());
        }
        out.vpn = out.interfaces.iter().find(|i| i.kind == InterfaceKind::Vpn).map(|i| i.name.clone());
        let physical_primary = out
            .primary_interface()
            .filter(|i| i.kind != InterfaceKind::Vpn)
            .cloned()
            .or_else(|| out.interfaces.iter().find(|i| i.kind != InterfaceKind::Vpn && i.gateway.is_some()).cloned());
        if let Some(p) = &physical_primary {
            out.primary = Some(p.id.clone());
        }
        out.router_ip = physical_primary.and_then(|i| i.gateway).filter(|g| g.parse::<Ipv4Addr>().is_ok());
        out.connected = out.primary.is_some();
        out.metered = self.metered;
    }

    fn refresh_wifi(&mut self) {
        if self.wifi_at.is_some_and(|t| t.elapsed().as_secs() < 10) {
            return;
        }
        self.wifi_at = Some(Instant::now());
        self.wifi.clear();
        let mut negotiated = 0u32;
        let mut h = HANDLE::default();
        // SAFETY: out-pointers to locals.
        if unsafe { WlanOpenHandle(2, None, &mut negotiated, &mut h) } != 0 {
            return;
        }
        let mut list: *mut WLAN_INTERFACE_INFO_LIST = std::ptr::null_mut();
        // SAFETY: valid client handle.
        if unsafe { WlanEnumInterfaces(h, None, &mut list) } == 0 && !list.is_null() {
            let l = unsafe { &*list };
            let items = unsafe { std::slice::from_raw_parts(l.InterfaceInfo.as_ptr(), l.dwNumberOfItems as usize) };
            for info in items {
                let mut size = 0u32;
                let mut data: *mut core::ffi::c_void = std::ptr::null_mut();
                // SAFETY: valid handle + interface GUID. Fails with ACCESS_DENIED when Windows
                // location access is off for desktop apps (24H2+) — the SSID then stays hidden.
                let rc = unsafe { WlanQueryInterface(h, &info.InterfaceGuid, wlan_intf_opcode_current_connection, None, &mut size, &mut data, None) };
                if rc == 0 && !data.is_null() {
                    let attrs = unsafe { &*(data as *const WLAN_CONNECTION_ATTRIBUTES) };
                    let s = &attrs.wlanAssociationAttributes.dot11Ssid;
                    let ssid = String::from_utf8_lossy(&s.ucSSID[..(s.uSSIDLength as usize).min(32)]).to_string();
                    let q = attrs.wlanAssociationAttributes.wlanSignalQuality.min(100) as u8;
                    self.wifi.insert(guid_string(&info.InterfaceGuid), (ssid, q));
                    unsafe { WlanFreeMemory(data) };
                }
            }
            unsafe { WlanFreeMemory(list as _) };
        }
        unsafe {
            WlanCloseHandle(h, None);
        }
    }

    fn refresh_metered(&mut self) {
        if self.metered_at.is_some_and(|t| t.elapsed().as_secs() < 30) {
            return;
        }
        self.metered_at = Some(Instant::now());
        self.metered = metered().unwrap_or(false);
    }
}

fn guid_string(g: &GUID) -> String {
    format!("{{{g:?}}}").to_ascii_lowercase()
}

fn best_interface() -> Option<u32> {
    let sin = SOCKADDR_IN {
        sin_family: AF_INET,
        sin_addr: windows::Win32::Networking::WinSock::IN_ADDR {
            S_un: windows::Win32::Networking::WinSock::IN_ADDR_0 { S_addr: u32::from_ne_bytes([1, 1, 1, 1]) },
        },
        ..Default::default()
    };
    let mut index = 0u32;
    // SAFETY: sockaddr_in cast to sockaddr, as the API expects.
    let rc = unsafe { GetBestInterfaceEx(&sin as *const SOCKADDR_IN as *const SOCKADDR, &mut index) };
    (rc == 0).then_some(index)
}

fn metered() -> windows::core::Result<bool> {
    use windows::Networking::Connectivity::{NetworkCostType, NetworkInformation};
    super::ensure_winrt();
    let profile = NetworkInformation::GetInternetConnectionProfile()?;
    let cost = profile.GetConnectionCost()?;
    let t = cost.NetworkCostType()?;
    Ok(t == NetworkCostType::Fixed || t == NetworkCostType::Variable || cost.Roaming()? || cost.OverDataLimit()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vpn_detection() {
        assert!(is_vpn("Tailscale Tunnel", "Tailscale", 53));
        assert!(is_vpn("WireGuard Tunnel", "wg0", 53));
        assert!(!is_vpn("Intel(R) Wi-Fi 6E AX211 160MHz", "Wi-Fi", 71));
    }
}
