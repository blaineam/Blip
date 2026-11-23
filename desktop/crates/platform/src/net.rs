//! Reachability: ping, router ping, traceroute/MTR and the WAN address. On Windows every probe
//! is `IcmpSendEcho2` from IP Helper — unprivileged, unlike raw sockets — and a traceroute is
//! just echoes with rising TTLs, so Blip needs no `tracert.exe` and no admin. Elsewhere the
//! system `ping`/`traceroute` tools are used.

use std::net::{IpAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use blip_core::trace::{HopAccumulator, HopProbe, HopStats};

pub fn resolve(host: &str) -> Option<IpAddr> {
    if let Ok(ip) = host.parse() {
        return Some(ip);
    }
    let addrs: Vec<IpAddr> = (host, 0).to_socket_addrs().ok()?.map(|a| a.ip()).collect();
    addrs.iter().find(|a| a.is_ipv4()).or(addrs.first()).copied()
}

/// One echo; RTT in ms.
pub fn ping(host: &str, timeout_ms: u32) -> Option<f64> {
    if !blip_core::trace::is_valid_host(host) {
        return None;
    }
    let ip = resolve(host)?;
    #[cfg(windows)]
    {
        crate::win::icmp::echo(ip, None, timeout_ms).and_then(|r| r.rtt_ms.filter(|_| r.reached))
    }
    #[cfg(not(windows))]
    {
        system_ping(ip, timeout_ms)
    }
}

#[cfg(not(windows))]
fn system_ping(ip: IpAddr, timeout_ms: u32) -> Option<f64> {
    let mut cmd = std::process::Command::new(if ip.is_ipv6() && cfg!(target_os = "macos") {
        "ping6"
    } else {
        "ping"
    });
    cmd.arg("-c").arg("1");
    #[cfg(target_os = "macos")]
    cmd.arg("-t").arg(timeout_ms.div_ceil(1000).max(1).to_string());
    #[cfg(not(target_os = "macos"))]
    cmd.arg("-W").arg(timeout_ms.div_ceil(1000).max(1).to_string());
    let out = cmd.arg(ip.to_string()).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let i = text.find("time=")?;
    text[i + 5..]
        .split_whitespace()
        .next()?
        .trim_end_matches("ms")
        .parse()
        .ok()
}

#[cfg(not(windows))]
pub fn default_gateway() -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        let table = std::fs::read_to_string("/proc/net/route").ok()?;
        for line in table.lines().skip(1) {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() > 2 && f[1] == "00000000" {
                let g = u32::from_str_radix(f[2], 16).ok()?;
                return Some(std::net::Ipv4Addr::from(g.to_le_bytes()).to_string());
            }
        }
        None
    }
    #[cfg(not(target_os = "linux"))]
    {
        let out = std::process::Command::new("route")
            .args(["-n", "get", "default"])
            .output()
            .ok()?;
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .find_map(|l| l.trim().strip_prefix("gateway:").map(|g| g.trim().to_string()))
    }
}

/// Pings the WAN target and the router every 5 s on its own thread, so sampling never blocks.
pub struct Pinger {
    state: Arc<Mutex<PingerState>>,
    stop: Arc<AtomicBool>,
}

#[derive(Default)]
struct PingerState {
    target: String,
    router: Option<String>,
    wan: Option<f64>,
    router_ms: Option<f64>,
}

impl Pinger {
    pub fn start() -> Self {
        let state = Arc::new(Mutex::new(PingerState {
            target: "1.1.1.1".into(),
            ..Default::default()
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let (st, sp) = (state.clone(), stop.clone());
        std::thread::Builder::new()
            .name("blip-pinger".into())
            .spawn(move || {
                while !sp.load(Ordering::Relaxed) {
                    let (target, router) = {
                        let g = st.lock().unwrap();
                        (g.target.clone(), g.router.clone())
                    };
                    let wan = ping(&target, 1500);
                    let r = router.as_deref().and_then(|r| ping(r, 1000));
                    {
                        let mut g = st.lock().unwrap();
                        g.wan = wan;
                        g.router_ms = r;
                    }
                    for _ in 0..50 {
                        if sp.load(Ordering::Relaxed) {
                            return;
                        }
                        std::thread::sleep(Duration::from_millis(100));
                    }
                }
            })
            .ok();
        Self { state, stop }
    }

    pub fn set_target(&self, host: &str) {
        if blip_core::trace::is_valid_host(host) {
            self.state.lock().unwrap().target = host.to_string();
        }
    }

    pub fn set_router(&self, ip: &str) {
        self.state.lock().unwrap().router = Some(ip.to_string());
    }

    pub fn latest(&self) -> (Option<f64>, Option<f64>) {
        let g = self.state.lock().unwrap();
        (g.wan, g.router_ms)
    }
}

impl Drop for Pinger {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// A live MTR session: repeated traceroute passes folded into per-hop stats until stopped.
#[derive(Clone, Default)]
pub struct Traceroute {
    inner: Arc<Mutex<TraceInner>>,
}

#[derive(Default)]
struct TraceInner {
    /// Bumped by every start/stop; a worker exits when it no longer matches.
    generation: u64,
    host: String,
    acc: HopAccumulator,
    running: bool,
    passes: u32,
    error: Option<String>,
    reached_at: Option<u32>,
}

#[derive(Debug, Clone, Default)]
pub struct TraceSnapshot {
    pub host: String,
    pub hops: Vec<HopStats>,
    pub running: bool,
    pub passes: u32,
    pub error: Option<String>,
}

impl Traceroute {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn snapshot(&self) -> TraceSnapshot {
        let g = self.inner.lock().unwrap();
        TraceSnapshot {
            host: g.host.clone(),
            hops: g.acc.snapshot(),
            running: g.running,
            passes: g.passes,
            error: g.error.clone(),
        }
    }

    pub fn is_running(&self) -> bool {
        self.inner.lock().unwrap().running
    }

    pub fn stop(&self) {
        let mut g = self.inner.lock().unwrap();
        g.generation += 1;
        g.running = false;
    }

    /// Starts (or restarts) tracing `host`. `on_update` fires after every hop.
    pub fn start(&self, host: &str, on_update: Option<Arc<dyn Fn() + Send + Sync>>) -> Result<(), String> {
        if !blip_core::trace::is_valid_host(host) {
            return Err(blip_core::tf(
                "“%@” isn't a valid hostname or IP address.",
                &[&host],
            ));
        }
        let generation = {
            let mut g = self.inner.lock().unwrap();
            let generation = g.generation + 1;
            *g = TraceInner {
                generation,
                host: host.to_string(),
                running: true,
                ..Default::default()
            };
            generation
        };
        let inner = self.inner.clone();
        let host = host.to_string();
        let notify = move || {
            if let Some(f) = &on_update {
                f();
            }
        };
        std::thread::Builder::new()
            .name("blip-trace".into())
            .spawn(move || {
                let live = || inner.lock().unwrap().generation == generation;
                let Some(ip) = resolve(&host) else {
                    let mut g = inner.lock().unwrap();
                    if g.generation == generation {
                        g.running = false;
                        g.error = Some("Couldn't resolve that host.".into());
                    }
                    drop(g);
                    notify();
                    return;
                };
                while live() {
                    let max = inner.lock().unwrap().reached_at.unwrap_or(30);
                    for ttl in 1..=max {
                        if !live() {
                            break;
                        }
                        let (probe, reached) = probe_hop(ip, ttl);
                        {
                            let mut g = inner.lock().unwrap();
                            if g.generation != generation {
                                break;
                            }
                            g.acc.ingest(&probe);
                            if reached {
                                g.reached_at = Some(ttl);
                                g.acc.truncate_after(ttl);
                            }
                        }
                        notify();
                        if reached {
                            break;
                        }
                    }
                    if !live() {
                        break;
                    }
                    inner.lock().unwrap().passes += 1;
                    std::thread::sleep(Duration::from_millis(500));
                }
                notify();
            })
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}

/// One probe at `ttl`. Returns the hop and whether it was the destination.
fn probe_hop(ip: IpAddr, ttl: u32) -> (HopProbe, bool) {
    #[cfg(windows)]
    {
        match crate::win::icmp::echo(ip, Some(ttl as u8), 1000) {
            Some(r) => (
                HopProbe {
                    hop: ttl,
                    host: r.from.map(|a| a.to_string()),
                    rtt_ms: r.rtt_ms,
                },
                r.reached,
            ),
            None => (
                HopProbe {
                    hop: ttl,
                    host: None,
                    rtt_ms: None,
                },
                false,
            ),
        }
    }
    #[cfg(not(windows))]
    {
        // Portable fallback: one-probe traceroute to exactly this TTL.
        let out = std::process::Command::new("traceroute")
            .args([
                "-n",
                "-q",
                "1",
                "-w",
                "1",
                "-f",
                &ttl.to_string(),
                "-m",
                &ttl.to_string(),
                &ip.to_string(),
            ])
            .output();
        let text = out
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default();
        let probe = text.lines().find_map(HopProbe::parse).unwrap_or(HopProbe {
            hop: ttl,
            host: None,
            rtt_ms: None,
        });
        let reached = probe.host.as_deref() == Some(&ip.to_string());
        (HopProbe { hop: ttl, ..probe }, reached)
    }
}
