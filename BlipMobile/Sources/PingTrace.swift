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

enum ICMPSocketError: Error, LocalizedError {
    case socketFailed(Int32)
    case resolveFailed(String)
    var errorDescription: String? {
        switch self {
        case .socketFailed(let errno_): return "ICMP socket failed (errno \(errno_))"
        case .resolveFailed(let host): return "Couldn't resolve \(host)"
        }
    }
}

enum ICMPProbe {
    /// Resolve an IPv4 for the host (ICMP datagram sockets here are v4; v6 is a follow-up).
    static func resolveIPv4(_ host: String) throws -> sockaddr_in {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
            throw ICMPSocketError.resolveFailed(host)
        }
        defer { freeaddrinfo(res) }
        var addr = sockaddr_in()
        memcpy(&addr, first.pointee.ai_addr, min(MemoryLayout<sockaddr_in>.size, Int(first.pointee.ai_addrlen)))
        return addr
    }

    /// One echo probe: send ICMP echo with the given TTL, wait up to timeout for any ICMP
    /// response on the socket. Returns (responderAddress, rtt, isEchoReply).
    static func probe(addr: sockaddr_in, ttl: Int32?, sequence: UInt16,
                      timeout: Double) throws -> (from: String, rttMs: Double, reachedDestination: Bool)? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { throw ICMPSocketError.socketFailed(errno) }
        defer { close(fd) }

        if let ttl { var t = ttl; setsockopt(fd, IPPROTO_IP, IP_TTL, &t, socklen_t(MemoryLayout<Int32>.size)) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // ICMP echo request: type 8, code 0. On a datagram ICMP socket the kernel manages the
        // identifier; the checksum is still ours to compute.
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xff)
        for i in 8..<16 { packet[i] = UInt8((Int(sequence) + i) & 0xff) }   // payload pattern
        let checksum = icmpChecksum(packet)
        packet[2] = UInt8(checksum >> 8); packet[3] = UInt8(checksum & 0xff)

        var dest = addr
        let start = CFAbsoluteTimeGetCurrent()
        let sent = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, packet, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 512)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
            }
        }
        guard n > 0 else { return nil }   // timeout
        let rtt = (CFAbsoluteTimeGetCurrent() - start) * 1000

        var ipBytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = from.sin_addr
        inet_ntop(AF_INET, &sin, &ipBytes, socklen_t(INET_ADDRSTRLEN))
        let ip = String(decoding: ipBytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)

        // XNU (macOS/iOS alike) delivers the full IP datagram on ICMP dgram sockets — the
        // ICMP header sits AFTER the IP header (unlike Linux). Field-verified: reading
        // byte 0 (0x45) as the ICMP type made traceroute never see its echo reply.
        var type = buffer[0]
        if n > 20, buffer[0] >> 4 == 4 {
            let ihl = Int(buffer[0] & 0x0f) * 4
            if n > ihl { type = buffer[ihl] }
        }
        // Echo reply = destination; also accept "the responder IS the target" (belt and
        // suspenders for stacks that strip the header).
        var target = addr.sin_addr
        var targetBytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &target, &targetBytes, socklen_t(INET_ADDRSTRLEN))
        let targetIP = String(decoding: targetBytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (from: ip, rttMs: rtt, reachedDestination: type == 0 || ip == targetIP)
    }

    static func icmpChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i < bytes.count - 1 {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if bytes.count % 2 == 1 { sum += UInt32(bytes[bytes.count - 1]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }
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
