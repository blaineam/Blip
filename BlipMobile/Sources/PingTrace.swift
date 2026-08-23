import Foundation

// Ping + traceroute for iOS — the sandbox-legal way. iOS has no raw sockets, but it DOES allow
// ICMP DATAGRAM sockets (SOCK_DGRAM, IPPROTO_ICMP): the kernel fills in identifiers and, with
// IP_RECVTTL-adjacent behavior, delivers echo replies AND the ICMP errors our own probes
// provoke — which is exactly what traceroute needs (send echo with small TTL → the expiring
// hop's "time exceeded" arrives on our socket with the hop's source address). This is how the
// respectable iOS network tools do it; no helper, no entitlements, no private API.
//
// The Mac app's MTR lives in the unsandboxed helper; this is the same feature reshaped for
// what iOS grants. Continuous MTR-style loss stats are possible but v1 ships classic ping
// (repeating echo with RTT stats) and classic traceroute (one pass, per-hop RTT + address,
// geo-annotated when the GeoIP database is downloaded).

struct PingSample: Identifiable, Sendable, Equatable {
    let id = UUID()
    let sequence: Int
    let rttMs: Double?          // nil = timeout
}

struct TraceHop: Identifiable, Sendable, Equatable {
    let id = UUID()
    let ttl: Int
    let address: String?        // nil = no reply within timeout
    let rttMs: Double?
    var isDestination = false
}

@MainActor
final class PingRunner: ObservableObject {
    @Published private(set) var samples: [PingSample] = []
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?

    private var task: Task<Void, Never>?

    var stats: (sent: Int, received: Int, lossPercent: Int, avgMs: Double?, minMs: Double?, maxMs: Double?) {
        let sent = samples.count
        let rtts = samples.compactMap(\.rttMs)
        let loss = sent > 0 ? Int((Double(sent - rtts.count) / Double(sent) * 100).rounded()) : 0
        return (sent, rtts.count, loss,
                rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count),
                rtts.min(), rtts.max())
    }

    func toggle(host: String) { isRunning ? stop() : start(host: host) }
    func stop() { task?.cancel(); isRunning = false }

    /// Screenshot demo mode: adopt canned samples without touching the network.
    func seedDemo(_ demo: [PingSample]) { samples = demo }

    func start(host: String) {
        guard !isRunning, !host.isEmpty else { return }
        samples = []
        error = nil
        isRunning = true
        task = Task.detached { [weak self] in
            do {
                let addr = try ICMPProbe.resolveIPv4(host)
                var seq: UInt16 = 0
                while !Task.isCancelled {
                    seq &+= 1
                    let r = try? ICMPProbe.probe(addr: addr, ttl: nil, sequence: seq, timeout: 2)
                    let sample = PingSample(sequence: Int(seq), rttMs: r?.rttMs)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.samples.append(sample)
                        if self.samples.count > 50 { self.samples.removeFirst() }
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.error = (error as NSError).localizedDescription
                    self?.isRunning = false
                }
            }
        }
    }
}

@MainActor
final class TraceRunner: ObservableObject {
    @Published private(set) var hops: [TraceHop] = []
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?

    private var task: Task<Void, Never>?

    func toggle(host: String) { isRunning ? stop() : start(host: host) }
    func stop() { task?.cancel(); isRunning = false }

    /// Screenshot demo mode: adopt canned hops without touching the network.
    func seedDemo(_ demo: [TraceHop]) { hops = demo }

    func start(host: String, maxHops: Int = 30) {
        guard !isRunning, !host.isEmpty else { return }
        hops = []
        error = nil
        isRunning = true
        task = Task.detached { [weak self] in
            do {
                let addr = try ICMPProbe.resolveIPv4(host)
                var seq: UInt16 = 1000
                for ttl in 1...maxHops {
                    if Task.isCancelled { break }
                    seq &+= 1
                    let r = try? ICMPProbe.probe(addr: addr, ttl: Int32(ttl), sequence: seq, timeout: 1.5)
                    var hop = TraceHop(ttl: ttl, address: r?.from, rttMs: r?.rttMs)
                    hop.isDestination = r?.reachedDestination ?? false
                    let done = hop.isDestination
                    await MainActor.run { [weak self] in self?.hops.append(hop) }
                    if done { break }
                }
            } catch {
                await MainActor.run { [weak self] in self?.error = (error as NSError).localizedDescription }
            }
            await MainActor.run { [weak self] in self?.isRunning = false }
        }
    }
}
