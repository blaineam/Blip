import XCTest
@testable import Blip

final class CoreModelTests: XCTestCase {

    // MARK: HistoryBuffer

    func testHistoryBufferRingBehavior() {
        var buf = HistoryBuffer<Double>(capacity: 3, defaultValue: 0)
        XCTAssertEqual(buf.count, 0)
        XCTAssertNil(buf.latest)

        buf.append(1)
        buf.append(2)
        XCTAssertEqual(buf.values, [1, 2])
        XCTAssertEqual(buf.latest, 2)
        XCTAssertFalse(buf.isFull)

        buf.append(3)
        buf.append(4)   // wraps, evicting 1
        XCTAssertTrue(buf.isFull)
        XCTAssertEqual(buf.values, [2, 3, 4])
        XCTAssertEqual(buf.latest, 4)
        XCTAssertEqual(buf.count, 3)
    }

    // MARK: VolumeInfo / DriveHealth derived values

    func testVolumeInfoUsage() {
        let v = VolumeInfo(name: "X", mountPoint: "/Volumes/X", totalBytes: 1_000, freeBytes: 250)
        XCTAssertEqual(v.usedBytes, 750)
        XCTAssertEqual(v.usagePercent, 75)
        XCTAssertEqual(v.id, "/Volumes/X")

        let empty = VolumeInfo(name: "Z", mountPoint: "/Volumes/Z", totalBytes: 0, freeBytes: 0)
        XCTAssertEqual(empty.usagePercent, 0)
    }

    func testDriveHealthDerivedValues() {
        let healthy = Fixtures.drive(name: "A", percentageUsed: 8, tempC: 40, healthy: true)
        XCTAssertEqual(healthy.lifeRemaining, 92)
        XCTAssertTrue(healthy.isHealthy)

        let unknown = Fixtures.drive(name: "B", percentageUsed: nil, tempC: nil, healthy: true)
        XCTAssertNil(unknown.lifeRemaining)

        let failing = Fixtures.drive(name: "C", percentageUsed: 120, tempC: 70, healthy: false)
        XCTAssertEqual(failing.lifeRemaining, 0)   // clamped at 0
        XCTAssertFalse(failing.isHealthy)
    }

    // MARK: RecommendationsEngine

    func testQuietSnapshotYieldsNoRecommendations() {
        var s = Fixtures.snapshot()
        s.memory.pressureLevel = 0
        s.memory.swapUsed = 0
        XCTAssertTrue(RecommendationsEngine.analyze(s).isEmpty)
    }

    func testCPUHogRecommendationSkipsSystemProcesses() {
        var s = Fixtures.snapshot()
        s.topProcessesByCPU = [
            Blip.ProcessInfo(id: 10, name: "WindowServer", cpu: 99, memory: 0, icon: nil, isUserOwned: true),
            Blip.ProcessInfo(id: 11, name: "RogueApp", cpu: 92, memory: 0, icon: nil, isUserOwned: true),
            Blip.ProcessInfo(id: 12, name: "rootd", cpu: 95, memory: 0, icon: nil, isUserOwned: false),
        ]
        let recs = RecommendationsEngine.analyze(s)
        let hog = recs.first { $0.id == "cpu-hog" }
        XCTAssertNotNil(hog)
        XCTAssertTrue(hog!.title.contains("RogueApp"), "must skip WindowServer and non-user processes")
    }

    func testMemoryPressureAndSwapRules() {
        var s = Fixtures.snapshot()
        s.memory.pressureLevel = 2
        XCTAssertTrue(RecommendationsEngine.analyze(s).contains { $0.id == "mem-pressure" && $0.severity == .critical })

        s.memory.pressureLevel = 0
        s.memory.swapUsed = 4_000_000_000
        let recs = RecommendationsEngine.analyze(s)
        XCTAssertTrue(recs.contains { $0.id == "mem-swap" })
        XCTAssertFalse(recs.contains { $0.id == "mem-pressure" })
    }

    func testDiskFullAndSmartRules() {
        var s = Fixtures.snapshot()
        s.disk.volumes[0] = VolumeInfo(name: "Macintosh HD", mountPoint: "/", totalBytes: 1_000, freeBytes: 50)
        XCTAssertTrue(RecommendationsEngine.analyze(s).contains { $0.id == "disk-full" })

        s.disk.drives = [Fixtures.drive(name: "Dying SSD", percentageUsed: 85, tempC: 50, healthy: false)]
        let recs = RecommendationsEngine.analyze(s)
        XCTAssertTrue(recs.contains { $0.id.hasPrefix("smart-") && $0.severity == .critical })

        s.disk.drives = [Fixtures.drive(name: "Worn SSD", percentageUsed: 85, tempC: 50, healthy: true)]
        XCTAssertTrue(RecommendationsEngine.analyze(s).contains { $0.id.hasPrefix("ssd-life-") })
    }

    func testThermalAndBatteryRules() {
        var s = Fixtures.snapshot()
        s.system.thermalLevel = .critical
        XCTAssertTrue(RecommendationsEngine.analyze(s).contains { $0.id == "thermal" && $0.severity == .critical })

        s.system.thermalLevel = .nominal
        s.battery.health = 72
        s.battery.condition = "Service Recommended"
        let recs = RecommendationsEngine.analyze(s)
        XCTAssertTrue(recs.contains { $0.id == "batt-health" })
        XCTAssertTrue(recs.contains { $0.id == "batt-service" })
    }

    func testRecommendationsSortedBySeverity() {
        var s = Fixtures.snapshot()
        s.memory.pressureLevel = 2                       // critical
        s.battery.health = 72                            // info
        s.system.thermalLevel = .serious                 // warning
        let recs = RecommendationsEngine.analyze(s)
        let severities = recs.map(\.severity.rawValue)
        XCTAssertEqual(severities, severities.sorted(by: >))
    }

    // MARK: TOTP (helper IPC auth)

    func testTOTPGenerateValidates() {
        let token = TOTP.generate()
        XCTAssertEqual(token.count, 6)
        XCTAssertTrue(token.allSatisfy(\.isNumber))
        XCTAssertTrue(TOTP.validate(token))
        XCTAssertFalse(TOTP.validate("000001"))
        XCTAssertFalse(TOTP.validate(""))
    }

    // MARK: netstat parsing

    func testParseNetstatTotals() {
        let output = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0        16384 <Link#1>                        100000     0  900000000   100000     0  900000000     0
        en0        1500  <Link#12>    aa:bb:cc:dd:ee:ff 5000000     0 6000000000  2000000     0 1500000000     0
        en0        1500  192.168.1     192.168.1.10     5000000     - 6000000000  2000000     - 1500000000     -
        en5        1500  <Link#13>    11:22:33:44:55:66  300000     0  250000000   100000     0   50000000     0
        utun0      1380  <Link#20>                          500     0     400000      300     0     200000     0
        """
        let totals = NetworkMonitor.parseNetstatTotals(output)
        // Only en* <Link rows count: en0 + en5; loopback/utun/dup-IP rows excluded.
        XCTAssertEqual(totals.down, 6_250_000_000)
        XCTAssertEqual(totals.up, 1_550_000_000)
    }

    // MARK: Helper IPC framing + wire types

    func testMessageFramingRoundTrip() throws {
        let request = HelperRequest(type: "traceroute", token: "123456",
                                    pid: nil, force: nil, action: "start", host: "1.1.1.1")
        let frame = try MessageFraming.encode(request)

        let length = MessageFraming.decodeLength(from: frame.prefix(4))
        XCTAssertEqual(Int(length!), frame.count - 4)

        let decoded = try JSONDecoder().decode(HelperRequest.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded.type, "traceroute")
        XCTAssertEqual(decoded.action, "start")
        XCTAssertEqual(decoded.host, "1.1.1.1")
        XCTAssertNil(decoded.pid)

        XCTAssertNil(MessageFraming.decodeLength(from: Data([0, 1])), "short header must be rejected")
    }

    func testHelperResponseRoundTripWithHops() throws {
        var response = HelperResponse(type: "traceroute", token: "654321", data: nil, message: nil)
        response.running = true
        response.hops = [HelperTraceHop(hop: 1, host: "192.168.1.1", sent: 10, recv: 9,
                                        lossPct: 10, lastMs: 1.2, avgMs: 1.5, bestMs: 0.9, worstMs: 3.1)]
        let frame = try MessageFraming.encode(response)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded.hops?.count, 1)
        XCTAssertEqual(decoded.hops?.first?.lossPct, 10)
        XCTAssertEqual(decoded.running, true)
    }

    // MARK: Volume enumeration (local syscalls only)

    func testReadVolumesIncludesRootFirst() {
        let volumes = DiskMonitor.readVolumes()
        XCTAssertFalse(volumes.isEmpty)
        XCTAssertEqual(volumes.first?.mountPoint, "/")
        XCTAssertGreaterThan(volumes.first!.totalBytes, 0)
    }
}
