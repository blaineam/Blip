//! MTR-style per-hop statistics, folded from repeated traceroute passes. The Mac parses
//! `/usr/sbin/traceroute` output; on Windows the probes come straight from `IcmpSendEcho2`
//! with a TTL, so the accumulator takes typed hops (a text parser is kept for Linux's
//! `traceroute -n -q 1`).

use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub struct HopProbe {
    pub hop: u32,
    /// Responder, or None for a timeout.
    pub host: Option<String>,
    pub rtt_ms: Option<f64>,
}

impl HopProbe {
    /// Parses `" 1  192.168.1.1  1.234 ms"` / `" 5  *"`; None for headers and blank lines.
    pub fn parse(line: &str) -> Option<HopProbe> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        let hop: u32 = tokens.first()?.parse().ok()?;
        let mut host = None;
        let mut rtt = None;
        for (i, tok) in tokens.iter().enumerate().skip(1) {
            if *tok == "ms" && i > 1 {
                if let Ok(v) = tokens[i - 1].parse::<f64>() {
                    rtt = Some(v);
                }
            } else if *tok != "*" && *tok != "ms" && tok.parse::<f64>().is_err() && host.is_none() {
                host = Some(tok.to_string());
            }
        }
        Some(HopProbe { hop, host, rtt_ms: rtt })
    }
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct HopStats {
    pub hop: u32,
    pub host: String,
    pub sent: u32,
    pub recv: u32,
    pub loss_pct: f64,
    pub last_ms: Option<f64>,
    pub avg_ms: Option<f64>,
    pub best_ms: Option<f64>,
    pub worst_ms: Option<f64>,
}

#[derive(Debug, Default, Clone)]
struct Stat {
    host: Option<String>,
    sent: u32,
    recv: u32,
    last: Option<f64>,
    best: Option<f64>,
    worst: Option<f64>,
    total: f64,
}

#[derive(Debug, Default, Clone)]
pub struct HopAccumulator {
    hops: BTreeMap<u32, Stat>,
}

impl HopAccumulator {
    pub fn is_empty(&self) -> bool {
        self.hops.is_empty()
    }

    pub fn clear(&mut self) {
        self.hops.clear();
    }

    pub fn ingest(&mut self, p: &HopProbe) {
        let s = self.hops.entry(p.hop).or_default();
        if let Some(h) = &p.host {
            s.host = Some(h.clone());
        }
        s.sent += 1;
        if let Some(rtt) = p.rtt_ms {
            s.recv += 1;
            s.last = Some(rtt);
            s.total += rtt;
            s.best = Some(s.best.map_or(rtt, |b| b.min(rtt)));
            s.worst = Some(s.worst.map_or(rtt, |w| w.max(rtt)));
        }
    }

    pub fn ingest_text(&mut self, output: &str) {
        for line in output.lines() {
            if let Some(p) = HopProbe::parse(line) {
                self.ingest(&p);
            }
        }
    }

    /// Drops hops past the destination (a pass that reached it at hop N makes N+1.. noise).
    pub fn truncate_after(&mut self, hop: u32) {
        self.hops.retain(|k, _| *k <= hop);
    }

    pub fn snapshot(&self) -> Vec<HopStats> {
        self.hops
            .iter()
            .map(|(n, s)| HopStats {
                hop: *n,
                host: s.host.clone().unwrap_or_else(|| "*".into()),
                sent: s.sent,
                recv: s.recv,
                loss_pct: if s.sent > 0 { (s.sent - s.recv) as f64 / s.sent as f64 * 100.0 } else { 0.0 },
                last_ms: s.last,
                avg_ms: (s.recv > 0).then(|| s.total / s.recv as f64),
                best_ms: s.best,
                worst_ms: s.worst,
            })
            .collect()
    }
}

/// Validates a ping/traceroute target: hostnames and IP literals only, never a leading "-".
pub fn is_valid_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && !host.starts_with('-')
        && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':'))
}

/// Public, routable IPv4 — the hops worth geolocating.
pub fn is_public_ipv4(ip: &str) -> bool {
    let Ok(a) = ip.parse::<std::net::Ipv4Addr>() else { return false };
    let o = a.octets();
    !(a.is_private()
        || a.is_loopback()
        || a.is_link_local()
        || a.is_unspecified()
        || a.is_broadcast()
        || a.is_multicast()
        || (o[0] == 100 && (64..128).contains(&o[1])) // CGNAT
        || o[0] == 0
        || o[0] >= 240)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hop_lines() {
        assert_eq!(
            HopProbe::parse(" 1  192.168.1.1  1.234 ms"),
            Some(HopProbe { hop: 1, host: Some("192.168.1.1".into()), rtt_ms: Some(1.234) })
        );
        assert_eq!(HopProbe::parse(" 5  *"), Some(HopProbe { hop: 5, host: None, rtt_ms: None }));
        assert_eq!(HopProbe::parse("traceroute to 1.1.1.1"), None);
    }

    #[test]
    fn accumulates_mtr_stats() {
        let mut acc = HopAccumulator::default();
        acc.ingest_text(" 1  10.0.0.1  1.0 ms\n 2  *\n");
        acc.ingest_text(" 1  10.0.0.1  3.0 ms\n 2  8.8.8.8  20.0 ms\n");
        let s = acc.snapshot();
        assert_eq!(s[0].avg_ms, Some(2.0));
        assert_eq!(s[0].best_ms, Some(1.0));
        assert_eq!(s[0].worst_ms, Some(3.0));
        assert_eq!(s[1].loss_pct, 50.0);
        assert_eq!(s[1].host, "8.8.8.8");
    }

    #[test]
    fn host_validation() {
        assert!(is_valid_host("one.one.one.one"));
        assert!(is_valid_host("2606:4700::1111"));
        assert!(!is_valid_host("-n"));
        assert!(!is_valid_host("a b"));
        assert!(!is_valid_host("x;rm"));
    }

    #[test]
    fn public_ipv4() {
        assert!(is_public_ipv4("1.1.1.1"));
        assert!(!is_public_ipv4("192.168.1.1"));
        assert!(!is_public_ipv4("100.64.1.1"));
        assert!(!is_public_ipv4("nope"));
    }
}
