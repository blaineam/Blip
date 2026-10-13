import XCTest
import Combine
import SwiftUI
@testable import BlipMobile

// The Speed tab hosted in a real window against the real MobileSpeedTester: idle, seeded
// history (latest + older cards, grade grid, bufferbloat colouring), a live run against the
// loopback server (and cancelling it by tapping the button), and the failure line.

@MainActor
final class MobileSpeedScreenTests: XCTestCase {

    private var defaults: DefaultsGuard!
    private var oldSeconds = MobileSpeedTester.transferSeconds
    private var oldProbes = MobileSpeedTester.latencyProbesEnabled
    private let standardKeys = ["mobile.speed.source", "mobile.speed.server"]

    override func setUp() async throws {
        defaults = DefaultsGuard(standard: standardKeys, shared: ["speed.history", "widget.speed"])
        for k in standardKeys { UserDefaults.standard.removeObject(forKey: k) }
        MobileSharedStore.defaults.removeObject(forKey: "speed.history")
        oldSeconds = MobileSpeedTester.transferSeconds
        oldProbes = MobileSpeedTester.latencyProbesEnabled
        MobileSpeedTester.latencyProbesEnabled = false
    }

    override func tearDown() async throws {
        MobileSpeedTester.transferSeconds = oldSeconds
        MobileSpeedTester.latencyProbesEnabled = oldProbes
        defaults.restore()
    }

    private func host<V: View>(_ view: V) -> Hosted {
        let h = Hosted(view)
        addTeardownBlock { @MainActor in h.close() }
        return h
    }

    private func stats(interface: String = "Wi-Fi", metered: Bool = false) -> DeviceStats {
        var s = DeviceSnapshot.fixture()
        s.interfaceType = interface
        s.isExpensivePath = metered
        let st = DeviceStats()
        st.publishForTesting(s)
        return st
    }

    private func result(down: Double, up: Double? = nil, ping: Double? = nil, loaded: Double? = nil,
                        curve: Bool = false, interface: String = "Wi-Fi", source: String = "OpenSpeedTest",
                        at seconds: TimeInterval = 0) -> MobileSpeedResult {
        var r = MobileSpeedResult(downMbps: down, upMbps: up, pingMs: ping,
                                  date: Date(timeIntervalSince1970: 1_760_000_000 + seconds),
                                  interface: interface, source: source)
        r.loadedPingMs = loaded
        if curve {
            r.downCurve = (0..<30).map { Double($0) * down / 30 }
            r.upCurve = (0..<20).map { Double($0) * (up ?? 1) / 20 }
        }
        return r
    }

    private func seedHistory(_ items: [MobileSpeedResult]) throws {
        MobileSharedStore.defaults.set(try JSONEncoder().encode(items), forKey: "speed.history")
    }

    private func useServer(_ address: String) {
        UserDefaults.standard.set(SpeedSource.custom.rawValue, forKey: "mobile.speed.source")
        UserDefaults.standard.set(address, forKey: "mobile.speed.server")
    }

    private func waitFor<P: Publisher>(_ publisher: P, timeout: TimeInterval = 60,
                                       _ condition: @escaping (P.Output) -> Bool) async where P.Failure == Never {
        let reached = expectation(description: "condition reached")
        reached.assertForOverFulfill = false
        let sub = publisher.sink { if condition($0) { reached.fulfill() } }
        await fulfillment(of: [reached], timeout: timeout)
        sub.cancel()
    }

    // MARK: Idle

    func testIdleScreenWithNoHistoryShowsARestingGauge() {
        let tester = MobileSpeedTester()
        let h = host(SpeedScreen(tester: tester, stats: stats()))
        XCTAssertTrue(h.shows("speed.gauge"))
        XCTAssertTrue(h.shows("—"), "no result yet → an em dash, not 0")
        XCTAssertTrue(h.shows("Run Speed Test"))
        XCTAssertTrue(h.shows("Testing over Wi-Fi"))
        XCTAssertFalse(h.shows("metered"))
        XCTAssertFalse(h.shows("speed.result.down"))
        XCTAssertFalse(h.shows("History"))
    }

    func testMeteredCellularPathIsCalledOut() {
        let h = host(SpeedScreen(tester: MobileSpeedTester(), stats: stats(interface: "Cellular", metered: true)))
        XCTAssertTrue(h.shows("Testing over Cellular"))
        XCTAssertTrue(h.shows("metered"))
    }

    // MARK: Results + history

    func testLatestResultCardAndOlderHistoryCards() throws {
        try seedHistory([
            result(down: 100, at: 0),                                              // no up, no ping
            result(down: 300, up: 40, ping: 20, at: 60),                           // ping, no loaded ping
            result(down: 942, up: 851, ping: 12, loaded: 160, curve: true, at: 120), // bufferbloat > 100 ms
        ])
        let tester = MobileSpeedTester()
        XCTAssertEqual(tester.history.count, 3)
        let h = host(SpeedScreen(tester: tester, stats: stats()))

        XCTAssertTrue(h.shows("942"), "the gauge shows the latest download")
        XCTAssertTrue(h.shows("942 Mbps"))
        XCTAssertTrue(h.shows("851 Mbps"))
        XCTAssertTrue(h.shows("speed.result.ping"))
        XCTAssertTrue(h.shows("speed.result.loadedPing"))
        XCTAssertTrue(h.shows("speed.result.share"))
        XCTAssertTrue(h.shows("Reliably good for"), "the grade grid")
        XCTAssertTrue(h.shows("History"))
        // History lists the older runs newest-first: 300 then 100.
        XCTAssertTrue(h.shows("speed.history.0.down"))
        XCTAssertTrue(h.shows("speed.history.1.down"))
        XCTAssertFalse(h.shows("speed.history.2.down"))
        XCTAssertTrue(h.shows("speed.history.0.ping"))
        XCTAssertFalse(h.shows("speed.history.0.loadedPing"))
        XCTAssertTrue(h.shows("300 Mbps"))
        XCTAssertTrue(h.shows("100 Mbps"))
    }

    func testSourceMenuNamesTheConfiguredServer() {
        useServer("10.0.0.5:3000")
        let tester = MobileSpeedTester()
        XCTAssertEqual(tester.source, .custom)
        let h = host(SpeedScreen(tester: tester, stats: stats()))
        XCTAssertTrue(h.shows("10.0.0.5:3000"))
        XCTAssertTrue(h.shows("Configure"))
    }

    func testCustomSourceWithoutAServerPromptsForOne() {
        UserDefaults.standard.set(SpeedSource.custom.rawValue, forKey: "mobile.speed.source")
        let h = host(SpeedScreen(tester: MobileSpeedTester(), stats: stats()))
        XCTAssertTrue(h.shows("Set server…"))
        XCTAssertTrue(h.shows("My server (not set)"))
    }

    // MARK: Running + failing

    func testTappingRunWithoutAServerFailsWithAHintOnScreen() {
        UserDefaults.standard.set(SpeedSource.custom.rawValue, forKey: "mobile.speed.source")
        let tester = MobileSpeedTester()
        let h = host(SpeedScreen(tester: tester, stats: stats()))
        XCTAssertTrue(h.activate("speed.run"))
        guard case .failed(let why) = tester.phase else { return XCTFail("got \(tester.phase)") }
        XCTAssertTrue(why.contains("Settings"))
        XCTAssertTrue(h.shows("Set your server address"), "the phase line carries the reason")
        XCTAssertFalse(tester.isRunning)
    }

    func testLiveRunShowsTheCurveAndTheRunButtonCancelsIt() async throws {
        let server = try LoopbackHTTPServer(mode: .speedTest(downloadBytes: 4_000_000))
        defer { server.stop() }
        useServer(server.baseURL.absoluteString)
        MobileSpeedTester.transferSeconds = (30, 30)

        let tester = MobileSpeedTester()
        let h = host(SpeedScreen(tester: tester, stats: stats()))
        XCTAssertTrue(h.activate("speed.run"))
        XCTAssertTrue(tester.isRunning)
        await waitFor(tester.$downCurve) { !$0.isEmpty }
        h.settle()

        XCTAssertTrue(h.shows("Cancel"), "the run button flips to Cancel")
        XCTAssertTrue(h.shows("Mbps · downloading"))
        XCTAssertTrue(h.shows("download"), "curve legend")

        XCTAssertTrue(h.activate("speed.run"))
        XCTAssertEqual(tester.phase, .idle)
        XCTAssertNil(tester.lastResult, "a cancelled run records nothing")
        XCTAssertTrue(h.shows("Run Speed Test"))
    }
}
