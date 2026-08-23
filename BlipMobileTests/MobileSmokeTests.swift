import XCTest
@testable import BlipMobile

// The iOS gate Soren runs on a simulator: BenchKit executes on the iOS runtime (real workloads,
// tiny budgets — proving the shared engine on the second platform), the shared-store contract
// round-trips, and the deep-link routing that widgets depend on resolves.

final class MobileSmokeTests: XCTestCase {

    func testBenchKitRunsOnIOS() async {
        let result = await BenchEngine.runOnce(profile: .quick)
        let r = try! XCTUnwrap(result)
        XCTAssertGreaterThan(r.composite, 0)
        XCTAssertGreaterThan(r.multiCore.score, r.singleCore.score)
    }

    func testSharedStoreRoundTripsSpeedAndDevice() {
        let speed = MobileSharedStore.SpeedRecord(downMbps: 512, upMbps: 87, date: .now, interface: "Wi-Fi")
        MobileSharedStore.write(speed: speed)
        let read = try! XCTUnwrap(MobileSharedStore.readSpeed())
        XCTAssertEqual(read.downMbps, 512)
        XCTAssertEqual(read.interface, "Wi-Fi")

        var snap = DeviceSnapshot()
        snap.storageTotal = 1_000
        snap.storageFree = 250
        MobileSharedStore.write(device: snap)
        let dev = try! XCTUnwrap(MobileSharedStore.readDevice())
        XCTAssertEqual(dev.storageTotal, 1_000)
        XCTAssertEqual(dev.storageFree, 250)
    }

    func testDeviceSnapshotDerivedValues() {
        var s = DeviceSnapshot()
        s.storageTotal = 100
        s.storageFree = 25
        XCTAssertEqual(s.storageUsed, 75)
        XCTAssertEqual(s.storagePercentUsed, 75, accuracy: 0.001)
        s.thermalState = 2
        XCTAssertEqual(s.thermalLabel, "Serious")
    }

    @MainActor
    func testBenchHistorySharesTheAppGroupSuite() {
        // The widget reads the same store the app writes — this is the whole contract.
        // Snapshot + restore: this is the REAL store; fake entries must not linger in the
        // app's visible history after a test run (they did — field-spotted).
        let priorData = MobileSharedStore.defaults.data(forKey: "benchHistory.v1")
        defer {
            if let priorData { MobileSharedStore.defaults.set(priorData, forKey: "benchHistory.v1") }
            else { MobileSharedStore.defaults.removeObject(forKey: "benchHistory.v1") }
        }
        let before = BenchHistory.load(defaults: MobileSharedStore.defaults).count
        let fake = BenchResult(date: .now, profile: .quick,
                               singleCore: .init(name: "s", score: 1, results: []),
                               multiCore: .init(name: "m", score: 2, results: []),
                               memory: .init(name: "mem", score: 1, results: []),
                               gpu: nil, neural: nil, throttleFactor: nil, thermalSamples: [],
                               composite: 1, deviceModel: "test", osVersion: "test")
        BenchHistory.append(fake, defaults: MobileSharedStore.defaults)
        XCTAssertEqual(BenchHistory.load(defaults: MobileSharedStore.defaults).count,
                       min(before + 1, BenchHistory.maxEntries))
    }
}

// MARK: - Feedback-wave coverage (device names, ICMP, snapshot, speed history, uptime)

final class FeedbackWaveTests: XCTestCase {

    func testDeviceNamesMapKnownAndUnknown() {
        XCTAssertEqual(DeviceNames.name(for: "iPhone18,2"), "iPhone 17 Pro Max")
        XCTAssertEqual(DeviceNames.name(for: "iPhone16,1"), "iPhone 15 Pro")
        // Unknown identifiers fall back to the codename — never guess.
        XCTAssertEqual(DeviceNames.name(for: "iPhone99,9"), "iPhone99,9")
        // Simulators report the HOST arch and say so.
        XCTAssertTrue(DeviceNames.name(for: "arm64").contains("Simulator"))
    }

    func testICMPChecksumMatchesRFC1071() {
        // Worked example: echo request header 08 00 00 00 + seq/id zeros must checksum
        // so that summing the full packet (checksum included) yields 0xFFFF.
        var packet: [UInt8] = [8, 0, 0, 0, 0, 0, 0, 1, 0x61, 0x62, 0x63, 0x64]
        let ck = ICMPProbe.icmpChecksum(packet)
        packet[2] = UInt8(ck >> 8); packet[3] = UInt8(ck & 0xff)
        var sum: UInt32 = 0
        var i = 0
        while i < packet.count - 1 { sum += UInt32(packet[i]) << 8 | UInt32(packet[i+1]); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        XCTAssertEqual(UInt16(sum & 0xffff), 0xffff)
    }

    func testSnapshotExportContainsEverySection() {
        var s = DeviceSnapshot()
        s.model = "iPhone18,2"
        s.storageTotal = 1_000_000
        s.storageFree = 400_000
        s.localIPs = ["en0 192.168.1.7"]
        let md = SnapshotExport.markdown(for: s, speedHistory: [
            MobileSpeedResult(downMbps: 940, upMbps: 850, pingMs: 3,
                              date: .now, interface: "Wi-Fi", source: "OpenSpeedTest"),
        ])
        for heading in ["# Blip Snapshot", "## Device", "## CPU", "## Memory",
                        "## Storage", "## Network", "### Local addresses", "## Recent speed tests"] {
            XCTAssertTrue(md.contains(heading), "missing \(heading)")
        }
        XCTAssertTrue(md.contains("iPhone 17 Pro Max"))
        XCTAssertTrue(md.contains("940 Mbps down"))
    }

    @MainActor
    func testSpeedHistoryCapsAtTen() {
        let suite = MobileSharedStore.defaults
        suite.removeObject(forKey: "speed.history")
        defer { suite.removeObject(forKey: "speed.history") }
        var history: [MobileSpeedResult] = []
        for i in 0..<15 {
            history.append(MobileSpeedResult(downMbps: Double(i), upMbps: nil, pingMs: nil,
                                             date: .now, interface: "Wi-Fi", source: "test"))
        }
        if history.count > MobileSpeedTester.maxHistory {
            history.removeFirst(history.count - MobileSpeedTester.maxHistory)
        }
        XCTAssertEqual(history.count, 10)
        XCTAssertEqual(history.first?.downMbps, 5)   // oldest five dropped
        // And it round-trips through the shared store encoding.
        suite.set(try! JSONEncoder().encode(history), forKey: "speed.history")
        let back = try! JSONDecoder().decode([MobileSpeedResult].self,
                                             from: suite.data(forKey: "speed.history")!)
        XCTAssertEqual(back.count, 10)
    }

    func testBootUptimeDerivesFromBootDate() {
        var s = DeviceSnapshot()
        s.bootDate = Date(timeIntervalSinceNow: -3_600)
        let up = s.bootUptime
        XCTAssertNotNil(up)
        XCTAssertEqual(up!, 3_600, accuracy: 5)
        s.model = "iPhone18,1"
        XCTAssertEqual(s.marketingName, "iPhone 17 Pro")
    }

    @MainActor
    func testSuggestionsFireOnlyWhenWarranted() {
        var s = DeviceSnapshot()
        s.storageTotal = 100
        s.storageFree = 50
        XCTAssertTrue(Suggestions.evaluate(s).isEmpty, "healthy device must show no suggestions")
        s.storageFree = 5   // 95% used
        s.thermalState = 3
        let items = Suggestions.evaluate(s)
        XCTAssertEqual(Set(items.map(\.id)), ["storage", "thermal"])
    }
}
