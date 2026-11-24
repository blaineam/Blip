//! ICMP echo through IP Helper (`IcmpSendEcho2` / `Icmp6SendEcho2`): unprivileged on Windows,
//! and with a TTL in the request options it is also a traceroute probe — a hop that drops the
//! TTL answers "TTL expired in transit" from its own address.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::Instant;

use windows::Win32::NetworkManagement::IpHelper::*;
use windows::Win32::Networking::WinSock::{AF_INET6, IN6_ADDR, IN6_ADDR_0, SOCKADDR_IN6};

pub struct EchoResult {
    /// The address that answered (the hop, for a TTL-limited probe).
    pub from: Option<IpAddr>,
    pub rtt_ms: Option<f64>,
    /// True when the destination itself answered.
    pub reached: bool,
}

const PAYLOAD: [u8; 32] = *b"Blip ping ......................";

pub fn echo(ip: IpAddr, ttl: Option<u8>, timeout_ms: u32) -> Option<EchoResult> {
    match ip {
        IpAddr::V4(v4) => echo4(v4, ttl, timeout_ms),
        IpAddr::V6(v6) => echo6(v6, ttl, timeout_ms),
    }
}

fn options(ttl: Option<u8>) -> IP_OPTION_INFORMATION {
    IP_OPTION_INFORMATION {
        Ttl: ttl.unwrap_or(128),
        ..Default::default()
    }
}

fn echo4(ip: Ipv4Addr, ttl: Option<u8>, timeout_ms: u32) -> Option<EchoResult> {
    // SAFETY: plain handle creation; closed below.
    let h = unsafe { IcmpCreateFile() }.ok()?;
    let opts = options(ttl);
    let mut reply = vec![0u64; (std::mem::size_of::<ICMP_ECHO_REPLY>() + PAYLOAD.len() + 8 + 64) / 8 + 1];
    let reply_bytes = (reply.len() * 8) as u32;
    let start = Instant::now();
    // SAFETY: synchronous call (no event/APC); buffers live across it. Destination is in
    // network byte order.
    let n = unsafe {
        IcmpSendEcho2(
            h,
            None,
            None,
            None,
            u32::from_ne_bytes(ip.octets()),
            PAYLOAD.as_ptr() as _,
            PAYLOAD.len() as u16,
            Some(&opts),
            reply.as_mut_ptr() as _,
            reply_bytes,
            timeout_ms,
        )
    };
    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
    // SAFETY: handle from IcmpCreateFile.
    unsafe {
        let _ = IcmpCloseHandle(h);
    }
    if n == 0 {
        return Some(EchoResult {
            from: None,
            rtt_ms: None,
            reached: false,
        });
    }
    // SAFETY: IP Helper wrote at least one ICMP_ECHO_REPLY at the start of the buffer.
    let r = unsafe { &*(reply.as_ptr() as *const ICMP_ECHO_REPLY) };
    let from = Ipv4Addr::from(r.Address.to_ne_bytes());
    match r.Status {
        IP_SUCCESS => Some(EchoResult {
            from: Some(IpAddr::V4(from)),
            rtt_ms: Some(precise(r.RoundTripTime, elapsed)),
            reached: true,
        }),
        IP_TTL_EXPIRED_TRANSIT | IP_TIME_EXCEEDED | IP_TTL_EXPIRED_REASSEM => Some(EchoResult {
            from: Some(IpAddr::V4(from)),
            rtt_ms: Some(precise(r.RoundTripTime, elapsed)),
            reached: false,
        }),
        _ => Some(EchoResult {
            from: None,
            rtt_ms: None,
            reached: false,
        }),
    }
}

fn echo6(ip: Ipv6Addr, ttl: Option<u8>, timeout_ms: u32) -> Option<EchoResult> {
    // SAFETY: plain handle creation; closed below.
    let h = unsafe { Icmp6CreateFile() }.ok()?;
    let opts = options(ttl);
    let src = SOCKADDR_IN6 {
        sin6_family: AF_INET6,
        ..Default::default()
    };
    let dst = SOCKADDR_IN6 {
        sin6_family: AF_INET6,
        sin6_addr: IN6_ADDR {
            u: IN6_ADDR_0 { Byte: ip.octets() },
        },
        ..Default::default()
    };
    let mut reply =
        vec![0u64; (std::mem::size_of::<ICMPV6_ECHO_REPLY_LH>() + PAYLOAD.len() + 8 + 64) / 8 + 1];
    let reply_bytes = (reply.len() * 8) as u32;
    let start = Instant::now();
    // SAFETY: synchronous; buffers outlive the call.
    let n = unsafe {
        Icmp6SendEcho2(
            h,
            None,
            None,
            None,
            &src,
            &dst,
            PAYLOAD.as_ptr() as _,
            PAYLOAD.len() as u16,
            Some(&opts),
            reply.as_mut_ptr() as _,
            reply_bytes,
            timeout_ms,
        )
    };
    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
    // SAFETY: handle from Icmp6CreateFile.
    unsafe {
        let _ = IcmpCloseHandle(h);
    }
    if n == 0 {
        return Some(EchoResult {
            from: None,
            rtt_ms: None,
            reached: false,
        });
    }
    // SAFETY: IP Helper wrote an ICMPV6_ECHO_REPLY at the start of the buffer.
    let r = unsafe { &*(reply.as_ptr() as *const ICMPV6_ECHO_REPLY_LH) };
    let words = r.Address.sin6_addr;
    let from = Ipv6Addr::new(
        u16::from_be(words[0]),
        u16::from_be(words[1]),
        u16::from_be(words[2]),
        u16::from_be(words[3]),
        u16::from_be(words[4]),
        u16::from_be(words[5]),
        u16::from_be(words[6]),
        u16::from_be(words[7]),
    );
    let rtt = Some(precise(r.RoundTripTime, elapsed));
    match r.Status {
        IP_SUCCESS => Some(EchoResult {
            from: Some(IpAddr::V6(from)),
            rtt_ms: rtt,
            reached: true,
        }),
        IP_TTL_EXPIRED_TRANSIT | IP_TIME_EXCEEDED | IP_TTL_EXPIRED_REASSEM => Some(EchoResult {
            from: Some(IpAddr::V6(from)),
            rtt_ms: rtt,
            reached: false,
        }),
        _ => Some(EchoResult {
            from: None,
            rtt_ms: None,
            reached: false,
        }),
    }
}

/// IP Helper reports whole milliseconds (0 on a LAN). The call is synchronous, so the measured
/// wall time is a sub-millisecond upper bound; use it when it agrees with the kernel's figure.
fn precise(reported_ms: u32, measured_ms: f64) -> f64 {
    if measured_ms >= reported_ms as f64 && measured_ms < reported_ms as f64 + 1.5 {
        measured_ms
    } else {
        reported_ms as f64
    }
}
