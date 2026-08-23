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
        let before = BenchHistory.load(defaults: MobileSharedStore.defaults).count
        let fake = BenchResult(date: .now, profile: .quick,
                               singleCore: .init(name: "s", score: 1, results: []),
                               multiCore: .init(name: "m", score: 2, results: []),
                               memory: .init(name: "mem", score: 1, results: []),
                               gpu: nil, throttleFactor: nil, thermalSamples: [],
                               composite: 1, deviceModel: "test", osVersion: "test")
        BenchHistory.append(fake, defaults: MobileSharedStore.defaults)
        XCTAssertEqual(BenchHistory.load(defaults: MobileSharedStore.defaults).count,
                       min(before + 1, BenchHistory.maxEntries))
    }
}
