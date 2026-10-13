import XCTest
import Combine
@testable import BlipMobile

// The mobile speed tester's state machine end to end against the loopback HTTP server:
// self-hosted run, result recording + history cap + widget record, failures, cancel/toggle.
// The ICMP latency probes (public internet) are switched off through the tester's seam and the
// transfer is shortened, so each run is ~2 s and never leaves the machine.

@MainActor
final class MobileSpeedTesterTests: XCTestCase {

    private let standardKeys = ["mobile.speed.source", "mobile.speed.server"]
    private let sharedKeys = ["speed.history", "widget.speed"]

    override func setUp() async throws {
        let std = UserDefaults.standard
        let shared = MobileSharedStore.defaults
        var savedStd: [String: Any] = [:], savedShared: [String: Any] = [:]
        for k in standardKeys { if let v = std.object(forKey: k) { savedStd[k] = v } }
        for k in sharedKeys { if let v = shared.object(forKey: k) { savedShared[k] = v } }
        let (sk, shk) = (standardKeys, sharedKeys)
        let oldSeconds = MobileSpeedTester.transferSeconds
        let oldProbes = MobileSpeedTester.latencyProbesEnabled
        addTeardownBlock {
            for k in sk { UserDefaults.standard.removeObject(forKey: k) }
            for (k, v) in savedStd { UserDefaults.standard.set(v, forKey: k) }
            for k in shk { MobileSharedStore.defaults.removeObject(forKey: k) }
            for (k, v) in savedShared { MobileSharedStore.defaults.set(v, forKey: k) }
            MobileSpeedTester.transferSeconds = oldSeconds
            MobileSpeedTester.latencyProbesEnabled = oldProbes
        }
        for k in sk { std.removeObject(forKey: k) }
        for k in shk { shared.removeObject(forKey: k) }
        MobileSpeedTester.transferSeconds = (1.0, 1.0)
        MobileSpeedTester.latencyProbesEnabled = false
    }

    private func waitFor<P: Publisher>(_ publisher: P, timeout: TimeInterval = 60,
                                       _ condition: @escaping (P.Output) -> Bool) async where P.Failure == Never {
        let reached = expectation(description: "condition reached")
        reached.assertForOverFulfill = false
        let sub = publisher.sink { if condition($0) { reached.fulfill() } }
        await fulfillment(of: [reached], timeout: timeout)
        sub.cancel()
    }

    private func isTerminal(_ phase: MobileSpeedTester.Phase) -> Bool {
        if case .failed = phase { return true }
        return phase == .done
    }

    private func useServer(_ address: String) {
        UserDefaults.standard.set(SpeedSource.custom.rawValue, forKey: "mobile.speed.source")
        UserDefaults.standard.set(address, forKey: "mobile.speed.server")
    }

    // MARK: Self-hosted run

    func testCustomServerRunRecordsResultHistoryAndWidgetRecord() async throws {
        let server = try LoopbackHTTPServer(mode: .speedTest(downloadBytes: 4_000_000))
        defer { server.stop() }
        useServer("127.0.0.1:\(server.port)/")   // scheme-less + trailing slash are normalized

        let tester = MobileSpeedTester()
        XCTAssertEqual(tester.source, .custom)
        XCTAssertFalse(tester.isRunning)
        tester.start(interface: "Wi-Fi")
        XCTAssertTrue(tester.isRunning)
        XCTAssertEqual(tester.phase, .connecting)
        await waitFor(tester.$phase) { self.isTerminal($0) }

        XCTAssertEqual(tester.phase, .done, "ended in \(tester.phase)")
        let result = try XCTUnwrap(tester.lastResult)
        XCTAssertGreaterThan(result.downMbps, 0)
        XCTAssertGreaterThan(try XCTUnwrap(result.upMbps), 0)
        XCTAssertEqual(result.interface, "Wi-Fi")
        XCTAssertEqual(result.source, "127.0.0.1")
        XCTAssertNil(result.pingMs, "probes are off")
        XCTAssertNil(result.loadedPingMs)
        XCTAssertFalse(try XCTUnwrap(result.downCurve).isEmpty, "live samples feed the share-card curve")
        XCTAssertFalse(try XCTUnwrap(result.upCurve).isEmpty)
        XCTAssertEqual(tester.liveMbps, 0, "the dial returns to rest")
        XCTAssertEqual(tester.history.last?.id, result.id)
        XCTAssertTrue(server.requests.contains("GET /downloading"))
        XCTAssertTrue(server.requests.contains("POST /upload"))

        // The widget record carries the same numbers.
        let widget = try XCTUnwrap(MobileSharedStore.readSpeed())
        XCTAssertEqual(widget.downMbps, result.downMbps)
        XCTAssertEqual(widget.interface, "Wi-Fi")

        // A fresh tester (cold launch) shows the persisted last result.
        let relaunched = MobileSpeedTester()
        XCTAssertEqual(relaunched.lastResult?.id, result.id)
        XCTAssertEqual(relaunched.history.count, 1)
    }

    func testHistoryIsCappedAtTheMostRecentTen() async throws {
        let seeded = (0..<MobileSpeedTester.maxHistory).map {
            MobileSpeedResult(downMbps: Double($0 + 1), upMbps: nil, pingMs: nil,
                              date: Date(timeIntervalSince1970: Double($0)), interface: "Wi-Fi", source: "seed")
        }
        MobileSharedStore.defaults.set(try JSONEncoder().encode(seeded), forKey: "speed.history")
        let server = try LoopbackHTTPServer(mode: .speedTest(downloadBytes: 2_000_000))
        defer { server.stop() }
        useServer("http://127.0.0.1:\(server.port)")

        let tester = MobileSpeedTester()
        XCTAssertEqual(tester.history.count, 10)
        tester.start(interface: "Cellular")
        await waitFor(tester.$phase) { self.isTerminal($0) }
        XCTAssertEqual(tester.phase, .done)
        XCTAssertEqual(tester.history.count, MobileSpeedTester.maxHistory)
        XCTAssertEqual(tester.history.first?.downMbps, 2, "the oldest entry was dropped")
        XCTAssertEqual(tester.history.last?.interface, "Cellular")
    }

    // MARK: Failures

    func testBlankServerAddressFailsWithAHint() {
        useServer("   ")
        let tester = MobileSpeedTester()
        tester.start(interface: "Wi-Fi")
        guard case .failed(let why) = tester.phase else { return XCTFail("got \(tester.phase)") }
        XCTAssertTrue(why.contains("Settings"))
        XCTAssertFalse(tester.isRunning)
        XCTAssertNil(tester.lastResult)
    }

    func testUnreachableServerSurfacesTheNetworkError() async throws {
        let probe = try LoopbackHTTPServer(mode: .status(200))
        let dead = probe.baseURL.absoluteString
        probe.stop()
        useServer(dead)
        let tester = MobileSpeedTester()
        tester.start(interface: "Wi-Fi")
        await waitFor(tester.$phase) { self.isTerminal($0) }
        guard case .failed(let why) = tester.phase else { return XCTFail("got \(tester.phase)") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertNil(tester.lastResult, "a failed run records nothing")
        XCTAssertTrue(tester.history.isEmpty)
    }

    // MARK: Cancel / toggle

    func testToggleStartsThenCancelsAndNeverRecords() async throws {
        let server = try LoopbackHTTPServer(mode: .speedTest(downloadBytes: 4_000_000))
        defer { server.stop() }
        useServer(server.baseURL.absoluteString)
        MobileSpeedTester.transferSeconds = (30, 30)   // would run long if cancel did nothing

        let tester = MobileSpeedTester()
        tester.toggle(interface: "Wi-Fi")
        XCTAssertTrue(tester.isRunning)
        tester.start(interface: "Wi-Fi")               // a second start while running is ignored
        XCTAssertEqual(tester.phase, .connecting)
        tester.toggle(interface: "Wi-Fi")
        XCTAssertEqual(tester.phase, .idle)
        XCTAssertFalse(tester.isRunning)
        XCTAssertEqual(tester.liveMbps, 0)
        XCTAssertNil(tester.lastResult)
        XCTAssertTrue(tester.history.isEmpty)
    }

    // MARK: Model

    func testSourceChoiceIsPersistedAndLabelled() {
        let tester = MobileSpeedTester()
        tester.source = .custom
        XCTAssertEqual(UserDefaults.standard.string(forKey: "mobile.speed.source"), "custom")
        XCTAssertEqual(MobileSpeedTester().source, .custom)
        tester.source = .publicWidget
        XCTAssertEqual(MobileSpeedTester().source, .publicWidget)
        XCTAssertNotEqual(SpeedSource.custom.label, SpeedSource.publicWidget.label)
        XCTAssertEqual(SpeedSource.allCases.count, 2)
    }

    func testPreSecondEditionHistoryStillDecodes() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","downMbps":88.5,"upMbps":null,"pingMs":null,
          "date":0,"interface":"Wi-Fi","source":"OpenSpeedTest"}]
        """
        MobileSharedStore.defaults.set(Data(json.utf8), forKey: "speed.history")
        let tester = MobileSpeedTester()
        XCTAssertEqual(tester.history.count, 1)
        XCTAssertEqual(tester.lastResult?.downMbps, 88.5)
        XCTAssertNil(tester.lastResult?.downCurve)
        XCTAssertNil(tester.lastResult?.loadedPingMs)
    }

    func testCorruptHistoryLoadsAsEmpty() {
        MobileSharedStore.defaults.set(Data("not json".utf8), forKey: "speed.history")
        XCTAssertTrue(MobileSpeedTester().history.isEmpty)
    }

    // MARK: Transfer engine pieces

    func testLiveCounterReportsThroughputOnceMeasurable() async throws {
        let reports = LockedBox<[Double]>([])
        let counter = LiveCounter(live: { m in reports.mutate { $0.append(m) } })
        counter.add(1_000_000)
        XCTAssertEqual(reports.value.count, 1, "the first buffer reports immediately")
        XCTAssertGreaterThan(reports.value[0], 0)
        XCTAssertGreaterThanOrEqual(counter.elapsed, 0)
    }
}

/// Tiny thread-safe box for values written from @Sendable callbacks.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}
