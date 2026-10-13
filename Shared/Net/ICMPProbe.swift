import Foundation

// ICMP datagram-socket probe — the sandbox-legal ping shared by the iOS network tools
// and the Mac speed tester's latency measurements. XNU (macOS and iOS alike) delivers
// the full IP datagram on these sockets; parsing accounts for it.

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

        // Read until a datagram that actually answers THIS probe arrives (or the deadline
        // passes): a stray ICMP message (a gateway's unreachable/redirect for other traffic)
        // must not be mistaken for the reply.
        let deadline = start + timeout
        let targetIP = dotted(addr.sin_addr)
        while true {
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
            let ip = dotted(from.sin_addr)

            switch classify(Array(buffer.prefix(n)), sequence: sequence, targetIP: targetIP) {
            case .echoReply: return (from: ip, rttMs: rtt, reachedDestination: true)
            case .hop: return (from: ip, rttMs: rtt, reachedDestination: ip == targetIP)
            case .unrelated:
                if CFAbsoluteTimeGetCurrent() >= deadline { return nil }
            }
        }
    }

    static func dotted(_ addr: in_addr) -> String {
        var a = addr
        var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &bytes, socklen_t(INET_ADDRSTRLEN))
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    enum ReplyKind: Equatable { case echoReply, hop, unrelated }

    /// Classify one datagram received on the ICMP socket. XNU (macOS/iOS alike) delivers the
    /// full IP datagram — the ICMP header sits AFTER the IP header (unlike Linux). Field-
    /// verified: reading byte 0 (0x45) as the ICMP type made traceroute never see its echo
    /// reply. A header-less datagram (stacks that strip it) is read from byte 0.
    /// - `.echoReply`: type 0 carrying our sequence.
    /// - `.hop`: time-exceeded (11) / destination-unreachable (3) quoting OUR echo (sequence
    ///   and destination match) — a traceroute hop or a path refusal.
    /// - `.unrelated`: anything else (other traffic's ICMP, a different probe's reply).
    static func classify(_ datagram: [UInt8], sequence: UInt16, targetIP: String) -> ReplyKind {
        var offset = 0
        if datagram.count > 20, datagram[0] >> 4 == 4 {
            let ihl = Int(datagram[0] & 0x0f) * 4
            guard datagram.count > ihl else { return .unrelated }
            offset = ihl
        }
        guard datagram.count >= offset + 8 else { return .unrelated }
        func seq(at o: Int) -> UInt16 { UInt16(datagram[o + 6]) << 8 | UInt16(datagram[o + 7]) }
        switch datagram[offset] {
        case 0:
            return seq(at: offset) == sequence ? .echoReply : .unrelated
        case 3, 11:
            // ICMP header (8) + quoted IP header + the first 8 bytes of our echo request.
            let q = offset + 8
            guard datagram.count > q, datagram[q] >> 4 == 4 else { return .unrelated }
            let qihl = Int(datagram[q] & 0x0f) * 4
            guard qihl >= 20, datagram.count >= q + qihl + 8, datagram[q + qihl] == 8 else { return .unrelated }
            guard seq(at: q + qihl) == sequence else { return .unrelated }
            let dst = datagram[(q + 16)..<(q + 20)].map(String.init).joined(separator: ".")
            return dst == targetIP ? .hop : .unrelated
        default:
            return .unrelated
        }
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
