//! ICMP without root: Linux "ping sockets" (`SOCK_DGRAM` + `IPPROTO_ICMP`), allowed for every
//! group in `net.ipv4.ping_group_range` — the default on Ubuntu, Debian/Raspberry Pi OS, Fedora,
//! SteamOS and RHEL-family systemd. With a TTL set and `IP_RECVERR` on, the router that drops
//! the probe sends "time exceeded", which the kernel queues on the socket's error queue along
//! with the router's address: a traceroute hop, the way `tracepath` works. Where ping sockets
//! are disabled, `crate::net` falls back to the setuid/setcap system tools.

use std::mem::{size_of, zeroed};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

pub struct EchoResult {
    /// The address that answered (the hop, for a TTL-limited probe).
    pub from: Option<IpAddr>,
    pub rtt_ms: Option<f64>,
    /// True when the destination itself answered.
    pub reached: bool,
}

const PAYLOAD: [u8; 32] = *b"Blip ping ......................";
static SEQ: AtomicU16 = AtomicU16::new(1);

fn open(v6: bool) -> Option<OwnedFd> {
    let (domain, proto) = if v6 {
        (libc::AF_INET6, libc::IPPROTO_ICMPV6)
    } else {
        (libc::AF_INET, libc::IPPROTO_ICMP)
    };
    // SAFETY: plain socket(2); ownership moves into OwnedFd.
    let fd = unsafe { libc::socket(domain, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, proto) };
    // SAFETY: fd is a fresh descriptor we own.
    (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Whether this system lets unprivileged users open ping sockets.
pub fn available() -> bool {
    static OK: OnceLock<bool> = OnceLock::new();
    *OK.get_or_init(|| open(false).is_some())
}

fn set_int(fd: i32, level: i32, name: i32, value: i32) {
    // SAFETY: setsockopt with a pointer to a live int.
    unsafe {
        libc::setsockopt(
            fd,
            level,
            name,
            &value as *const i32 as *const libc::c_void,
            size_of::<i32>() as libc::socklen_t,
        );
    }
}

pub fn checksum(data: &[u8]) -> u16 {
    let mut sum = 0u32;
    for c in data.chunks(2) {
        let w = if c.len() == 2 {
            u16::from_be_bytes([c[0], c[1]])
        } else {
            u16::from_be_bytes([c[0], 0])
        };
        sum += w as u32;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

pub fn echo(ip: IpAddr, ttl: Option<u8>, timeout_ms: u32) -> Option<EchoResult> {
    let v6 = ip.is_ipv6();
    let sock = open(v6)?;
    let fd = sock.as_raw_fd();
    if v6 {
        set_int(fd, libc::IPPROTO_IPV6, libc::IPV6_RECVERR, 1);
        if let Some(t) = ttl {
            set_int(fd, libc::IPPROTO_IPV6, libc::IPV6_UNICAST_HOPS, t as i32);
        }
    } else {
        set_int(fd, libc::IPPROTO_IP, libc::IP_RECVERR, 1);
        if let Some(t) = ttl {
            set_int(fd, libc::IPPROTO_IP, libc::IP_TTL, t as i32);
        }
    }

    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let mut pkt = [0u8; 8 + PAYLOAD.len()];
    pkt[0] = if v6 { 128 } else { 8 };
    pkt[6..8].copy_from_slice(&seq.to_be_bytes());
    pkt[8..].copy_from_slice(&PAYLOAD);
    // The kernel rewrites the identifier (it's the socket's "port") and the checksum.
    let c = checksum(&pkt);
    pkt[2..4].copy_from_slice(&c.to_be_bytes());

    let start = Instant::now();
    // SAFETY: sockaddr structs are fully initialised and sized for sendto.
    let sent = unsafe {
        match ip {
            IpAddr::V4(a) => {
                let mut sa: libc::sockaddr_in = zeroed();
                sa.sin_family = libc::AF_INET as libc::sa_family_t;
                sa.sin_addr.s_addr = u32::from_ne_bytes(a.octets());
                libc::sendto(
                    fd,
                    pkt.as_ptr() as *const libc::c_void,
                    pkt.len(),
                    0,
                    &sa as *const _ as *const libc::sockaddr,
                    size_of::<libc::sockaddr_in>() as libc::socklen_t,
                )
            }
            IpAddr::V6(a) => {
                let mut sa: libc::sockaddr_in6 = zeroed();
                sa.sin6_family = libc::AF_INET6 as libc::sa_family_t;
                sa.sin6_addr.s6_addr = a.octets();
                libc::sendto(
                    fd,
                    pkt.as_ptr() as *const libc::c_void,
                    pkt.len(),
                    0,
                    &sa as *const _ as *const libc::sockaddr,
                    size_of::<libc::sockaddr_in6>() as libc::socklen_t,
                )
            }
        }
    };
    if sent < 0 {
        // No route, network down: the probe simply got no answer.
        return Some(EchoResult {
            from: None,
            rtt_ms: None,
            reached: false,
        });
    }

    let deadline = start + Duration::from_millis(timeout_ms as u64);
    let mut buf = [0u8; 1500];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Some(EchoResult {
                from: None,
                rtt_ms: None,
                reached: false,
            });
        }
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one pollfd on the stack.
        let n = unsafe { libc::poll(&mut pfd, 1, left.as_millis().max(1) as i32) };
        if n <= 0 {
            continue;
        }
        let rtt = start.elapsed().as_secs_f64() * 1000.0;
        if pfd.revents & libc::POLLERR != 0 {
            if let Some((from, seq_back)) = read_error(fd, v6, &mut buf) {
                if seq_back == Some(seq) {
                    return Some(EchoResult {
                        reached: from == Some(ip),
                        from,
                        rtt_ms: Some(rtt),
                    });
                }
            }
            continue;
        }
        if pfd.revents & libc::POLLIN != 0 {
            // SAFETY: buffer is ours and sized.
            let got = unsafe { libc::recv(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0) };
            if got >= 8 {
                let reply = if v6 { 129 } else { 0 };
                let back = u16::from_be_bytes([buf[6], buf[7]]);
                if buf[0] == reply && back == seq {
                    return Some(EchoResult {
                        from: Some(ip),
                        rtt_ms: Some(rtt),
                        reached: true,
                    });
                }
            }
        }
    }
}

/// One entry from the socket error queue: the ICMP sender (a router on the path) and the
/// sequence number of the probe it is about.
fn read_error(fd: i32, v6: bool, buf: &mut [u8]) -> Option<(Option<IpAddr>, Option<u16>)> {
    let mut control = [0u64; 64];
    let mut iov = libc::iovec {
        iov_base: buf.as_mut_ptr() as *mut libc::c_void,
        iov_len: buf.len(),
    };
    // SAFETY: msghdr points at stack buffers that outlive the call; CMSG macros walk the
    // control buffer the kernel just filled.
    unsafe {
        let mut msg: libc::msghdr = zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
        msg.msg_controllen = std::mem::size_of_val(&control) as _;
        let got = libc::recvmsg(fd, &mut msg, libc::MSG_ERRQUEUE);
        if got < 0 {
            return None;
        }
        // The queued payload is our own echo request: its sequence number says which probe.
        let seq = (got >= 8).then(|| u16::from_be_bytes([buf[6], buf[7]]));
        let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
        while !cmsg.is_null() {
            let c = &*cmsg;
            let ours = if v6 {
                c.cmsg_level == libc::SOL_IPV6 && c.cmsg_type == libc::IPV6_RECVERR
            } else {
                c.cmsg_level == libc::SOL_IP && c.cmsg_type == libc::IP_RECVERR
            };
            if ours {
                let ee = libc::CMSG_DATA(cmsg) as *const libc::sock_extended_err;
                let origin = (*ee).ee_origin;
                if origin == libc::SO_EE_ORIGIN_ICMP || origin == libc::SO_EE_ORIGIN_ICMP6 {
                    let off = ee.add(1) as *const libc::sockaddr;
                    let from = match (*off).sa_family as i32 {
                        libc::AF_INET => {
                            let sa = &*(off as *const libc::sockaddr_in);
                            Some(IpAddr::V4(Ipv4Addr::from(sa.sin_addr.s_addr.to_ne_bytes())))
                        }
                        libc::AF_INET6 => {
                            let sa = &*(off as *const libc::sockaddr_in6);
                            Some(IpAddr::V6(Ipv6Addr::from(sa.sin6_addr.s6_addr)))
                        }
                        _ => None,
                    };
                    return Some((from, seq));
                }
                return Some((None, seq));
            }
            cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
        }
        Some((None, seq))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc1071_checksum() {
        // Example from RFC 1071 §3.
        let d = [0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7];
        assert_eq!(checksum(&d), !0xddf2);
    }
}
