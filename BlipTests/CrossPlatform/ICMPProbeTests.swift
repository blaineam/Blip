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
        let r = try XCTUnwrap(reply, "loopback always answers an echo")
        XCTAssertEqual(r.from, "127.0.0.1")
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
}
