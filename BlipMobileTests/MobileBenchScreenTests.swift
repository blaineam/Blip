import XCTest
import Combine
import SwiftUI
@testable import BlipMobile

// The Bench tab hosted against the real BenchEngine: the intro, a stored result's score card
// (delta vs best, category bars, throttling + thermal steps), the history list, the battery /
// thermal guardrails, and the live narrated run (a real quick run, cancelled once a leg lands).

@MainActor
final class MobileBenchScreenTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let name = "blip.benchscreen.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func host<V: View>(_ view: V) -> Hosted {
        let h = Hosted(view)
        addTeardownBlock { @MainActor in h.close() }
        return h
    }

    private func stats(battery: String = "Charging", thermal: Int = 0) -> DeviceStats {
        var s = DeviceSnapshot.fixture()
        s.batteryState = battery
        s.thermalState = thermal
        let st = DeviceStats()
        st.publishForTesting(s)
        return st
    }

    private func result(_ composite: Double, profile: BenchProfile = .full, throttle: Double? = 0.8,
                        gpu: Bool = true, neural: Bool = true, thermal: Bool = true, at seconds: TimeInterval) -> BenchResult {
        BenchResult(date: Date(timeIntervalSince1970: 1_760_000_000 + seconds), profile: profile,
                    singleCore: .init(name: "s", score: composite * 0.5, results: []),
                    multiCore: .init(name: "m", score: composite * 4.7, results: []),
                    memory: .init(name: "mem", score: composite * 0.8, results: []),
                    gpu: gpu ? .init(name: "g", score: composite * 0.5, results: []) : nil,
                    neural: neural ? .init(name: "n", score: composite * 0.6, results: []) : nil,
                    throttleFactor: throttle,
                    thermalSamples: thermal ? (0..<6).map {
                        BenchThermalSample(atSeconds: Double($0) * 5, temperatureC: nil, fanRPM: nil, thermalState: $0 > 3 ? 2 : 0)
                    } : [],
                    composite: composite, deviceModel: "iPhone18,1", osVersion: "iOS")
    }

    private func engine(with results: [BenchResult]) -> BenchEngine {
        let defaults = isolatedDefaults()
        for r in results { BenchHistory.append(r, defaults: defaults) }
        return BenchEngine(defaults: defaults)
    }

    private func waitFor<P: Publisher>(_ publisher: P, timeout: TimeInterval = 120,
                                       _ condition: @escaping (P.Output) -> Bool) async where P.Failure == Never {
        let reached = expectation(description: "condition reached")
        reached.assertForOverFulfill = false
        let sub = publisher.sink { if condition($0) { reached.fulfill() } }
        await fulfillment(of: [reached], timeout: timeout)
        sub.cancel()
    }

    // MARK: Idle

    func testIntroShowsBeforeTheFirstRun() {
        let e = engine(with: [])
        let h = host(BenchScreen(engine: e, stats: stats()))
        XCTAssertTrue(h.shows("bench.intro"))
        XCTAssertTrue(h.shows("Run Full Benchmark"))
        XCTAssertFalse(h.shows("bench.score"))
        XCTAssertFalse(h.shows("History"))
        XCTAssertFalse(h.shows("bench.guardrail.battery"))
    }

    func testGuardrailsWarnOnBatteryAndAHotDevice() {
        let h = host(BenchScreen(engine: engine(with: []), stats: stats(battery: "On battery", thermal: 2)))
        XCTAssertTrue(h.shows("bench.guardrail.battery"))
        XCTAssertTrue(h.shows("Device is already serious"))
        let calm = host(BenchScreen(engine: engine(with: []), stats: stats()))
        XCTAssertFalse(calm.shows("bench.guardrail.battery"))
        XCTAssertFalse(calm.shows("already"))
    }

    // MARK: Results

    func testFullRunScoreCardShowsDeltaAgainstBestAndThrottling() {
        let e = engine(with: [result(1_200, at: 0), result(1_000, profile: .quick, at: 60), result(1_500, at: 120)])
        XCTAssertEqual(e.lastResult?.composite, 1_500)
        let h = host(BenchScreen(engine: e, stats: stats()))
        XCTAssertFalse(h.shows("bench.intro"))
        XCTAssertTrue(h.shows("bench.score"))
        XCTAssertTrue(h.shows("1,500"))
        XCTAssertTrue(h.shows("+25%"), "1500 vs the previous best full run of 1200: \(h.accessibilityStrings.sorted())")
        XCTAssertTrue(h.shows("vs best"))
        XCTAssertTrue(h.shows("Sustained load loses 20%"))
        XCTAssertTrue(h.shows("bench.share"))
        // History, newest first, with the profile chip.
        XCTAssertTrue(h.shows("bench.history.row.0"))
        XCTAssertTrue(h.shows("bench.history.row.2"))
        XCTAssertFalse(h.shows("bench.history.row.3"))
        XCTAssertTrue(h.shows("quick"))
    }

    func testSlowerFullRunShowsANegativeDelta() {
        let e = engine(with: [result(1_500, at: 0), result(1_200, at: 60)])
        let h = host(BenchScreen(engine: e, stats: stats()))
        XCTAssertTrue(h.shows("-20%"))
    }

    func testQuickRunCardHasNoDeltaNoGpuNoThrottleLine() {
        let e = engine(with: [result(1_500, at: 0), result(900, profile: .quick, throttle: nil, gpu: false, neural: false, thermal: false, at: 60)])
        let h = host(BenchScreen(engine: e, stats: stats()))
        XCTAssertTrue(h.shows("900"))
        XCTAssertFalse(h.shows("vs best"))
        XCTAssertFalse(h.shows("Sustained load"))
        XCTAssertFalse(h.shows("No throttling"))
    }

    func testUnthrottledRunSaysSo() {
        let e = engine(with: [result(1_300, throttle: 1.0, at: 0)])
        let h = host(BenchScreen(engine: e, stats: stats()))
        XCTAssertTrue(h.shows("No throttling under sustained load"))
    }

    func testScoreCardStandsAlone() {
        let r = result(1_234, at: 0)
        let h = host(ScoreCard(result: r, history: [r]))
        XCTAssertTrue(h.shows("bench.score"))
        XCTAssertFalse(h.shows("vs best"), "a first run has nothing to compare with")
    }

    // MARK: Running

    func testRunningViewNarratesLegsAndTheRunButtonCancels() async throws {
        let e = engine(with: [])
        let h = host(BenchScreen(engine: e, stats: stats()))
        XCTAssertTrue(h.activate("bench.run"), "Run Full Benchmark")
        XCTAssertTrue(e.isRunning)
        XCTAssertTrue(h.shows("bench.running"))
        XCTAssertTrue(h.shows("Cancel"))

        await waitFor(e.$liveLegs) { $0.contains { $0.id == "single" } }
        h.settle()
        XCTAssertTrue(h.shows("bench.leg.single"), "a finished leg animates in with its score")

        XCTAssertTrue(h.activate("bench.run"), "Cancel")
        await waitFor(e.$isRunning) { !$0 }
        h.settle()
        XCTAssertNil(e.lastResult)
        XCTAssertTrue(h.shows("bench.intro"))
    }
}
