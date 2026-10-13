import XCTest
import SwiftUI
@testable import BlipMobile

// The Overview drill-in screens, hosted in a real window with hand-built device snapshots so
// every branch of their ViewBuilders runs (full / sparse / edge-state snapshots) and the
// values on screen can be checked against the snapshot.

@MainActor
final class MobileDetailScreenTests: XCTestCase {

    private func stats(_ s: DeviceSnapshot = .fixture(), wan: String? = nil, samples: Int = 4) -> DeviceStats {
        let st = DeviceStats()
        for _ in 0..<samples { st.publishForTesting(s, wanIP: wan) }
        return st
    }

    private func host<V: View>(_ view: V) -> Hosted {
        let h = Hosted(view)
        addTeardownBlock { @MainActor in h.close() }
        return h
    }

    func testCPUDetailShowsTotalLoadAndCoreSplit() {
        let h = host(NavigationStack { CPUDetailScreen(stats: stats()) })
        XCTAssertTrue(h.shows("detail.cpu.total"), "strings: \(h.accessibilityStrings.sorted())")
        XCTAssertTrue(h.shows("37%"))
        XCTAssertTrue(h.shows("1.50"), "load average 1m")
        XCTAssertTrue(h.shows("detail.cpu.pcores"))
        XCTAssertTrue(h.shows("detail.cpu.ecores"))
    }

    func testCPUDetailOmitsTheCoreSplitWhereTheSystemHasNone() {
        var s = DeviceSnapshot.fixture()
        s.coresPerformance = 0; s.coresEfficiency = 0
        let h = host(NavigationStack { CPUDetailScreen(stats: stats(s)) })
        XCTAssertTrue(h.shows("detail.cpu.cores"))
        XCTAssertFalse(h.shows("detail.cpu.pcores"))
    }

    func testMemoryDetailBreakdown() {
        let h = host(NavigationStack { MemoryDetailScreen(stats: stats()) })
        XCTAssertTrue(h.shows("detail.memory.total"))
        XCTAssertTrue(h.shows("detail.memory.available"))
        XCTAssertTrue(h.shows("detail.memory.wired"))
        // Without enough history the session chart is simply absent — no crash on empty rings.
        _ = host(NavigationStack { MemoryDetailScreen(stats: stats(samples: 1)) })
    }

    func testStorageDetailHostsTheDiskSection() {
        var s = DeviceSnapshot.fixture()
        s.storageFree = 20_000_000_000      // 96% used → the red gauge branch
        let h = host(NavigationStack { StorageDetailScreen(stats: stats(s)) })
        XCTAssertTrue(h.shows("detail.storage.free"))
        XCTAssertTrue(h.shows("detail.storage.purgeable"))
        XCTAssertTrue(h.shows("storage.disk.runInternal"))
        XCTAssertTrue(h.shows("storage.disk.pickFolder"))
    }

    func testNetworkDetailBadgesAddressesAndWAN() {
        let h = host(NavigationStack { NetworkDetailScreen(stats: stats(wan: "203.0.113.9")) })
        XCTAssertTrue(h.shows("detail.network.interface"))
        XCTAssertTrue(h.shows("detail.network.ip.en0"))
        XCTAssertTrue(h.shows("detail.network.ip.utun3"))
        XCTAssertTrue(h.shows("detail.network.vpn"))
        // The WAN address stays hidden behind the reveal button until it is tapped.
        XCTAssertFalse(h.shows("203.0.113.9"))
        XCTAssertTrue(h.shows("WAN IP"))
    }

    func testNetworkDetailWithNothingToShow() {
        var s = DeviceSnapshot.fixture()
        s.localIPs = []; s.vpnActive = false; s.isExpensivePath = false
        s.isConstrainedPath = false; s.radioTech = nil; s.interfaceType = "Offline"
        let h = host(NavigationStack { NetworkDetailScreen(stats: stats(s)) })
        XCTAssertTrue(h.shows("None"))
        XCTAssertFalse(h.shows("detail.network.ip.en0"))
    }

    func testBatteryDetailWithAndWithoutALevel() {
        let h = host(NavigationStack { BatteryDetailScreen(stats: stats()) })
        XCTAssertTrue(h.shows("64%"))
        XCTAssertTrue(h.shows("detail.battery.state"))
        var none = DeviceSnapshot.fixture()
        none.batteryLevel = nil; none.lowPowerMode = false
        let h2 = host(NavigationStack { BatteryDetailScreen(stats: stats(none)) })
        XCTAssertTrue(h2.shows("—"))
        XCTAssertFalse(h2.shows("64%"))
    }

    func testThermalDetailForEveryState() {
        for state in 0...3 {
            var s = DeviceSnapshot.fixture()
            s.thermalState = state
            let h = host(NavigationStack { ThermalDetailScreen(stats: stats(s)) })
            XCTAssertTrue(h.shows("detail.thermal.state"), "state \(state)")
            XCTAssertTrue(h.shows(s.thermalLabel), "state \(state) label")
        }
    }

    func testDeviceDetailIdentityAndUptime() {
        let h = host(NavigationStack { DeviceDetailScreen(stats: stats()) })
        XCTAssertTrue(h.shows("iPhone 17 Pro"))
        XCTAssertTrue(h.shows("detail.device.model"))
        XCTAssertTrue(h.shows("detail.device.uptime"))
        // No boot date and no big/little split → the sparse layout.
        var s = DeviceSnapshot.fixture()
        s.bootDate = nil; s.coresPerformance = 0
        _ = host(NavigationStack { DeviceDetailScreen(stats: stats(s)) })
    }

    func testCopyRowAndPlainRowRender() {
        let h = host(List {
            CopyRow(name: "Model", value: "iPhone18,1", monospaced: true, id: "row.copy")
            CopyRow(name: "OS", value: "27.0")
            PlainRow(name: "Free", value: "1 GB", id: "row.plain")
        })
        XCTAssertTrue(h.shows("row.copy"))
        XCTAssertTrue(h.shows("row.plain"))
    }
}
