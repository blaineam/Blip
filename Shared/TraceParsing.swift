import Foundation

// MTR-style accumulation of `/usr/sbin/traceroute -n -q 1` output, shared by the direct
// build's in-process runner (LocalTraceRunner) and Blip Helper's TraceSession so both
// parse hop lines identically.

/// One parsed traceroute hop line.
struct TraceHopLine: Equatable, Sendable {
    let hop: Int
    /// The responding address, or nil when the probe timed out (`*`).
    let host: String?
    /// Round-trip time in ms, or nil for a timeout.
    let rttMs: Double?

    /// Parses lines of the form `" 1  192.168.1.1  1.234 ms"` or `" 5  *"`. Returns nil for
    /// anything that isn't a hop line (the header, blank lines). With several probes per
    /// line the last RTT wins; the first non-numeric token is the responder.
    static func parse(_ rawLine: String) -> TraceHopLine? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first, let hopNum = Int(first) else { return nil }

        var host: String?
        var rtt: Double?
        var i = 1
        while i < tokens.count {
            let tok = tokens[i]
            if tok == "ms", i > 1, let ms = Double(tokens[i - 1]) {
                rtt = ms
            } else if tok != "*" && tok != "ms" && Double(tok) == nil {
                // Non-numeric, non-marker token → the hop host/IP.
                if host == nil { host = tok }
            }
            i += 1
        }
        return TraceHopLine(hop: hopNum, host: host, rttMs: rtt)
    }
}

/// Folds repeated traceroute passes into per-hop sent/received/loss/last/avg/best/worst.
/// Not thread-safe on its own; owners guard it with their lock.
struct TraceHopAccumulator {
    private struct HopStat {
        var host = "*"
        var sent = 0
        var recv = 0
        var last: Double?
        var best: Double?
        var worst: Double?
        var total: Double = 0
    }

    private var hops: [Int: HopStat] = [:]

    var isEmpty: Bool { hops.isEmpty }

    mutating func removeAll() { hops.removeAll() }

    /// Folds every hop line of one traceroute pass.
    mutating func ingest(output: String) {
        for line in output.components(separatedBy: "\n") { ingest(line: line) }
    }

    mutating func ingest(line: String) {
        guard let parsed = TraceHopLine.parse(line) else { return }
        var stat = hops[parsed.hop] ?? HopStat()
        if let host = parsed.host { stat.host = host }
        stat.sent += 1
        if let rtt = parsed.rttMs {
            stat.recv += 1
            stat.last = rtt
            stat.total += rtt
            stat.best = stat.best.map { min($0, rtt) } ?? rtt
            stat.worst = stat.worst.map { max($0, rtt) } ?? rtt
        }
        hops[parsed.hop] = stat
    }

    func snapshot() -> [HelperTraceHop] {
        hops.keys.sorted().map { num in
            let s = hops[num]!
            let loss = s.sent > 0 ? Double(s.sent - s.recv) / Double(s.sent) * 100 : 0
            let avg = s.recv > 0 ? s.total / Double(s.recv) : nil
            return HelperTraceHop(hop: num, host: s.host, sent: s.sent, recv: s.recv,
                                  lossPct: loss, lastMs: s.last, avgMs: avg,
                                  bestMs: s.best, worstMs: s.worst)
        }
    }
}
