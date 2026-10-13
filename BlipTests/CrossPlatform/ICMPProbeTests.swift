import XCTest
#if os(iOS)
@testable import BlipMobile
#else
@testable import Blip
#endif

// The sandbox-legal ICMP datagram probe behind iOS ping/traceroute and the Mac speed
// test's latency numbers — exercised against loopback only (no network dependency).

final class ICMPProbeTests: XCTestCase {

    func testResolveIPv4Literal() throws {
        let addr = try ICMPProbe.resolveIPv4("127.0.0.1")
        XCTAssertEqual(addr.sin_family, sa_family_t(AF_INET))
        XCTAssertEqual(UInt32(bigEndian: addr.sin_addr.s_addr), 0x7F00_0001)
    }

    func testResolveFailureIsATypedError() {
        // An empty name fails inside getaddrinfo without any DNS traffic.
        XCTAssertThrowsError(try ICMPProbe.resolveIPv4("")) { error in
            guard case ICMPSocketError.resolveFailed(let host) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(host, "")
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Couldn't resolve ")
        }
    }

    func testLoopbackEchoReturnsAnRTTFromTheTarget() throws {
        let addr = try ICMPProbe.resolveIPv4("127.0.0.1")
        let reply: (from: String, rttMs: Double, reachedDestination: Bool)?
        do {
            reply = try ICMPProbe.probe(addr: addr, ttl: nil, sequence: 7, timeout: 2)
        } catch ICMPSocketError.socketFailed(let code) {
            throw XCTSkip("ICMP datagram sockets unavailable here (errno \(code))")
        }
        // Hosts with a VPN / network extension (Tailscale) can swallow loopback echoes or have
        // a gateway answer them; that is the environment, not the probe, so skip rather than fail.
        guard let r = reply else { throw XCTSkip("loopback ICMP echo is filtered on this host") }
        guard r.from == "127.0.0.1" else { throw XCTSkip("loopback ICMP echo was answered by \(r.from), not loopback") }
        XCTAssertTrue(r.reachedDestination)
        XCTAssertGreaterThanOrEqual(r.rttMs, 0)
        XCTAssertLessThan(r.rttMs, 2_000)
    }

    func testChecksumOfAComputedPacketVerifiesToZero() {
        // RFC 1071: summing a packet that already carries its checksum yields 0 (i.e. ~0xFFFF).
        var packet: [UInt8] = [8, 0, 0, 0, 0x12, 0x34, 0x00, 0x07, 1, 2, 3, 4, 5, 6, 7]   // odd length
        let sum = ICMPProbe.icmpChecksum(packet)
        packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xff)
        XCTAssertEqual(ICMPProbe.icmpChecksum(packet), 0)
    }

    // MARK: reply classification (deterministic — synthesized datagrams)

    private func ipHeader(proto: UInt8 = 1, src: [UInt8], dst: [UInt8], payload: Int) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 20)
        h[0] = 0x45; h[8] = 64; h[9] = proto
        h[2] = UInt8((20 + payload) >> 8); h[3] = UInt8((20 + payload) & 0xff)
        h.replaceSubrange(12..<16, with: src); h.replaceSubrange(16..<20, with: dst)
        return h
    }

    private func echo(type: UInt8, seq: UInt16) -> [UInt8] {
        [type, 0, 0, 0, 0, 0, UInt8(seq >> 8), UInt8(seq & 0xff)]
    }

    private func reply(seq: UInt16) -> [UInt8] {
        ipHeader(src: [8, 8, 8, 8], dst: [10, 0, 0, 2], payload: 8) + echo(type: 0, seq: seq)
    }

    private func quoted(type: UInt8, seq: UInt16, dst: [UInt8], quotedType: UInt8 = 8) -> [UInt8] {
        let inner = ipHeader(src: [10, 0, 0, 2], dst: dst, payload: 8) + echo(type: quotedType, seq: seq)
        return ipHeader(src: [10, 0, 0, 1], dst: [10, 0, 0, 2], payload: 8 + inner.count)
            + [type, 0, 0, 0, 0, 0, 0, 0] + inner
    }

    func testEchoReplyWithMatchingSequenceIsAReply() {
        XCTAssertEqual(ICMPProbe.classify(reply(seq: 7), sequence: 7, targetIP: "8.8.8.8"), .echoReply)
    }

    func testEchoReplyForAnotherSequenceIsIgnored() {
        XCTAssertEqual(ICMPProbe.classify(reply(seq: 8), sequence: 7, targetIP: "8.8.8.8"), .unrelated)
    }

    func testHeaderlessEchoReplyIsReadFromByteZero() {
        XCTAssertEqual(ICMPProbe.classify(echo(type: 0, seq: 3) + [1, 2, 3, 4, 5, 6, 7, 8], sequence: 3, targetIP: "8.8.8.8"), .echoReply)
    }

    func testTimeExceededQuotingOurProbeIsAHop() {
        let d = quoted(type: 11, seq: 7, dst: [8, 8, 8, 8])
        XCTAssertEqual(ICMPProbe.classify(d, sequence: 7, targetIP: "8.8.8.8"), .hop)
        XCTAssertEqual(ICMPProbe.classify(quoted(type: 3, seq: 7, dst: [8, 8, 8, 8]), sequence: 7, targetIP: "8.8.8.8"), .hop)
    }

    func testTimeExceededForAnotherProbeOrDestinationIsIgnored() {
        XCTAssertEqual(ICMPProbe.classify(quoted(type: 11, seq: 9, dst: [8, 8, 8, 8]), sequence: 7, targetIP: "8.8.8.8"), .unrelated)
        XCTAssertEqual(ICMPProbe.classify(quoted(type: 11, seq: 7, dst: [1, 1, 1, 1]), sequence: 7, targetIP: "8.8.8.8"), .unrelated)
        XCTAssertEqual(ICMPProbe.classify(quoted(type: 11, seq: 7, dst: [8, 8, 8, 8], quotedType: 0), sequence: 7, targetIP: "8.8.8.8"), .unrelated)
    }

    func testOtherTypesAndTruncatedDatagramsAreIgnored() {
        // Redirect (5) and echo request (8) are not answers to our probe.
        XCTAssertEqual(ICMPProbe.classify(ipHeader(src: [10, 0, 0, 1], dst: [10, 0, 0, 2], payload: 8) + echo(type: 5, seq: 7), sequence: 7, targetIP: "8.8.8.8"), .unrelated)
        XCTAssertEqual(ICMPProbe.classify(ipHeader(src: [10, 0, 0, 1], dst: [10, 0, 0, 2], payload: 8) + echo(type: 8, seq: 7), sequence: 7, targetIP: "8.8.8.8"), .unrelated)
        XCTAssertEqual(ICMPProbe.classify([], sequence: 7, targetIP: "8.8.8.8"), .unrelated)
        XCTAssertEqual(ICMPProbe.classify([0, 0, 0], sequence: 7, targetIP: "8.8.8.8"), .unrelated)
        XCTAssertEqual(ICMPProbe.classify(Array(quoted(type: 11, seq: 7, dst: [8, 8, 8, 8]).prefix(40)), sequence: 7, targetIP: "8.8.8.8"), .unrelated)
        // IP header claiming more bytes than arrived.
        var bad = reply(seq: 7).prefix(21).map { $0 }; bad[0] = 0x4f
        XCTAssertEqual(ICMPProbe.classify(bad, sequence: 7, targetIP: "8.8.8.8"), .unrelated)
    }

    func testDottedFormatsAnAddress() throws {
        XCTAssertEqual(ICMPProbe.dotted(try ICMPProbe.resolveIPv4("192.0.2.9").sin_addr), "192.0.2.9")
    }
}
