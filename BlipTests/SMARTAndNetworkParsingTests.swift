import XCTest
@testable import Blip

// Byte- and text-level parsers behind the Disk and Network panels: the NVMe SMART/Health
// log, the ATA attribute table, 32-bit interface counter wrap, VPN detection and the
// netstat default-route parse.

final class SMARTAndNetworkParsingTests: XCTestCase {

    private func put(_ v: UInt64, at off: Int, in buf: inout [UInt8]) {
        for i in 0..<8 { buf[off + i] = UInt8(v >> (8 * UInt64(i)) & 0xff) }
    }

    func testNVMeLogDecodesSpecOffsetsLittleEndian() throws {
        var buf = [UInt8](repeating: 0, count: 512)
        buf[0] = 0x04                               // critical warning: reliability degraded
        buf[1] = 0x3A; buf[2] = 0x01                // 0x013A = 314 K → 41 °C
        buf[3] = 97; buf[4] = 10; buf[5] = 3        // spare, spare threshold, % used
        put(123_456, at: 32, in: &buf)              // data units read
        put(654_321, at: 48, in: &buf)              // data units written
        put(1_500, at: 112, in: &buf)               // power cycles
        put(8_760, at: 128, in: &buf)               // power-on hours
        put(42, at: 144, in: &buf)                  // unsafe shutdowns
        put(0x0102_0304_0506_0708, at: 160, in: &buf)  // media errors (all 8 bytes matter)

        let log = try XCTUnwrap(NVMeSMARTLog(bytes: buf))
        XCTAssertEqual(log.criticalWarning, 4)
        XCTAssertEqual(log.temperatureKelvin, 314)
        XCTAssertEqual(log.temperatureCelsius, 41)
        XCTAssertEqual(log.availableSpare, 97)
        XCTAssertEqual(log.spareThreshold, 10)
        XCTAssertEqual(log.percentUsed, 3)
        XCTAssertEqual(log.dataUnitsRead, 123_456)
        XCTAssertEqual(log.dataUnitsWritten, 654_321)
        XCTAssertEqual(log.powerCycles, 1_500)
        XCTAssertEqual(log.powerOnHours, 8_760)
        XCTAssertEqual(log.unsafeShutdowns, 42)
        XCTAssertEqual(log.mediaErrors, 0x0102_0304_0506_0708)
        XCTAssertEqual(log.smartStatus, "Failing", "any critical-warning bit fails the drive")

        buf[0] = 0
        XCTAssertEqual(NVMeSMARTLog(bytes: buf)?.smartStatus, "Verified")
    }

    func testNVMeLogRejectsShortBuffers() {
        XCTAssertNil(NVMeSMARTLog(bytes: []))
        XCTAssertNil(NVMeSMARTLog(bytes: [UInt8](repeating: 0, count: 167)))
        XCTAssertNotNil(NVMeSMARTLog(bytes: [UInt8](repeating: 0, count: 168)))
    }

    func testDriveHealthDerivesLifeAndBytesFromTheLog() throws {
        var buf = [UInt8](repeating: 0, count: 512)
        buf[5] = 120                                // wear can exceed 100 %
        put(2, at: 48, in: &buf)
        let log = try XCTUnwrap(NVMeSMARTLog(bytes: buf))
        let health = HelperDriveHealth(name: "SSD", bsdName: "disk0", isInternal: true, medium: "NVMe",
                                       smartStatus: log.smartStatus, percentageUsed: Int(log.percentUsed),
                                       dataUnitsWritten: log.dataUnitsWritten)
        XCTAssertEqual(health.lifeRemaining, 0, "never negative")
        XCTAssertEqual(health.bytesWritten, 1_024_000, "NVMe data units are 512,000 bytes")
    }

    private func ataTable(_ entries: [(id: UInt8, current: UInt8, raw: UInt64)]) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 512)
        for (i, e) in entries.enumerated() {
            let off = 2 + i * 12
            buf[off] = e.id
            buf[off + 3] = e.current
            for b in 0..<6 { buf[off + 5 + b] = UInt8(e.raw >> (8 * UInt64(b)) & 0xff) }
        }
        return buf
    }

    func testATAAttributesPickLifeTemperatureAndHours() {
        let attrs = ATASMARTAttributes.parse(ataTable([
            (id: 9, current: 99, raw: 12_345),      // power-on hours (raw)
            (id: 194, current: 38, raw: 0),         // temperature °C (normalized)
            (id: 231, current: 92, raw: 0),         // SSD life left
            (id: 233, current: 50, raw: 0),         // a second life attribute is ignored
        ]))
        XCTAssertEqual(attrs.powerOnHours, 12_345)
        XCTAssertEqual(attrs.tempC, 38)
        XCTAssertEqual(attrs.life, 92, "first life attribute wins")
    }

    func testATAAttributesIgnoreImplausibleValues() {
        let attrs = ATASMARTAttributes.parse(ataTable([
            (id: 9, current: 100, raw: 5_000_000),  // > 1M hours: a bridge returning junk
            (id: 194, current: 200, raw: 0),         // 200 °C
            (id: 231, current: 0, raw: 0),           // life 0 is "unknown" on these bridges
            (id: 0xFF, current: 50, raw: 0),
        ]))
        XCTAssertNil(attrs.powerOnHours)
        XCTAssertNil(attrs.tempC)
        XCTAssertNil(attrs.life)
        let empty = ATASMARTAttributes.parse([])
        XCTAssertNil(empty.life)
    }

    // MARK: Network

    func testWrapAwareDelta() {
        XCTAssertEqual(NetworkMonitor.wrapAwareDelta(current: 1_500, last: 1_000), 500)
        XCTAssertEqual(NetworkMonitor.wrapAwareDelta(current: 100, last: 100), 0)
        // The 32-bit counter wrapped: 4 GiB − 1000 → 500 is 1,500 bytes, not a negative jump.
        XCTAssertEqual(NetworkMonitor.wrapAwareDelta(current: 500, last: (1 << 32) - 1_000), 1_500)
    }

    func testVPNInterfaceClassification() {
        for vpn in ["utun0", "utun12", "tailscale0", "wg0"] { XCTAssertTrue(NetworkMonitor.isVPNInterface(vpn), vpn) }
        for not in ["en0", "lo0", "bridge0", "awdl0", "llw0", "anpi0"] { XCTAssertFalse(NetworkMonitor.isVPNInterface(not), not) }
    }

    func testDefaultGatewayParse() {
        let netstat = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            192.168.1.1        UGScg                 en0
        default            10.8.0.1           UGScIg              utun4
        127                127.0.0.1          UCS                   lo0
        """
        XCTAssertEqual(NetworkMonitor.parseDefaultGateway(netstat), "192.168.1.1", "first default route wins")
        XCTAssertEqual(NetworkMonitor.parseDefaultGateway("Routing tables\n"), "—")
    }

    func testDownsampleKeepsShapeAndCapsPoints() throws {
        XCTAssertNil(SpeedTester.downsample([]))
        XCTAssertEqual(SpeedTester.downsample([1, 2, 3]), [1, 2, 3], "short curves pass through")
        let long = (0..<240).map(Double.init)
        let down = try XCTUnwrap(SpeedTester.downsample(long))
        XCTAssertEqual(down.count, 80)
        XCTAssertEqual(down.first, 0)
        XCTAssertEqual(down, down.sorted(), "order preserved")
        XCTAssertEqual(down[1], 3, "evenly strided")
    }
}
