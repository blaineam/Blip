import XCTest
import Combine
@testable import BlipMobile

// BenchEngine's published state machine on the real (quick-profile) measurement: phases,
// live legs, history persistence into an isolated suite, cancel, toggle, and the one-at-a-time
// guard. The quick profile is ~6 s, so the success path is exercised once and the rest cancel.

@MainActor
final class BenchEngineTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let name = "blip.benchengine.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func waitFor<P: Publisher>(_ publisher: P, timeout: TimeInterval = 120,
                                       _ condition: @escaping (P.Output) -> Bool) async where P.Failure == Never {
        let reached = expectation(description: "condition reached")
        reached.assertForOverFulfill = false
        let sub = publisher.sink { if condition($0) { reached.fulfill() } }
        await fulfillment(of: [reached], timeout: timeout)
        sub.cancel()
    }

    func testQuickRunPublishesLegsRecordsHistoryAndSurvivesRelaunch() async throws {
        let defaults = isolatedDefaults()
        let engine = BenchEngine(defaults: defaults)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertNil(engine.lastResult)
        XCTAssertTrue(engine.history.isEmpty)

        let result = await engine.runAwaiting(profile: .quick)
        let r = try XCTUnwrap(result, "a quick run completes")

        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.progress, 1)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(r.profile, .quick)
        XCTAssertGreaterThan(r.composite, 0)
        XCTAssertGreaterThan(r.singleCore.score, 0)
        XCTAssertGreaterThan(r.multiCore.score, r.singleCore.score, "all cores out-run one core")
        XCTAssertGreaterThan(r.memory.score, 0)
        XCTAssertNil(r.throttleFactor, "the quick profile has no sustained phase")
        XCTAssertTrue(r.thermalSamples.isEmpty)
        XCTAssertFalse(r.deviceModel.isEmpty)

        let ids = engine.liveLegs.map(\.id)
        XCTAssertTrue(ids.contains("single") && ids.contains("multi") && ids.contains("memory"), "legs: \(ids)")
        XCTAssertEqual(Set(ids).count, ids.count, "each leg is published once, updated in place")

        XCTAssertEqual(engine.lastResult?.composite, r.composite)
        XCTAssertEqual(engine.history.count, 1)
        XCTAssertEqual(BenchHistory.load(defaults: defaults).count, 1)

        // A running engine refuses a second concurrent run.
        engine.start(profile: .quick)
        let refused = await engine.runAwaiting(profile: .quick)
        XCTAssertNil(refused, "one benchmark at a time")
        engine.cancel()
        await waitFor(engine.$isRunning) { !$0 }

        // Cold launch shows the stored result.
        let relaunched = BenchEngine(defaults: defaults)
        XCTAssertEqual(relaunched.lastResult?.composite, r.composite)
        XCTAssertEqual(relaunched.history.count, 1)
    }

    func testCancelledRunLeavesNoResultAndReturnsToIdle() async {
        let defaults = isolatedDefaults()
        let engine = BenchEngine(defaults: defaults)
        engine.toggle(profile: .quick)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.phase, .singleCore)
        engine.toggle(profile: .quick)               // second toggle cancels
        await waitFor(engine.$isRunning) { !$0 }

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(engine.progress, 0)
        XCTAssertNil(engine.lastResult)
        XCTAssertTrue(BenchHistory.load(defaults: defaults).isEmpty, "a cancelled run is never recorded")
    }

    func testRunOnceReturnsAResultWithoutPublishingState() async throws {
        let result = await BenchEngine.runOnce(profile: .quick, thermal: NullThermalSource())
        XCTAssertGreaterThan(try XCTUnwrap(result).composite, 0)
    }

    func testPhaseLabelsAreDistinctAndNonEmpty() {
        let phases: [BenchEngine.Phase] = [.idle, .singleCore, .multiCore, .memory, .gpu, .neural, .sustained, .done]
        let labels = phases.map(\.label)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(labels).count, phases.count)
    }

    func testThermalSources() {
        let null = NullThermalSource()
        XCTAssertNil(null.temperatureC())
        XCTAssertNil(null.fanRPM())

        let box = LatestThermalBox()
        XCTAssertNil(box.temperatureC())
        box.update(temperatureC: 61.5, fanRPM: 2_400)
        XCTAssertEqual(box.temperatureC(), 61.5)
        XCTAssertEqual(box.fanRPM(), 2_400)
        box.update(temperatureC: nil, fanRPM: nil)
        XCTAssertNil(box.temperatureC())
        XCTAssertNil(box.fanRPM())
    }

    func testCancelFlagSetAndReset() {
        let flag = CancelFlag()
        XCTAssertFalse(flag.isSet)
        flag.set()
        XCTAssertTrue(flag.isSet)
        flag.reset()
        XCTAssertFalse(flag.isSet)
    }

    func testBenchLiveLegEquality() {
        XCTAssertEqual(BenchLiveLeg(id: "gpu", name: "GPU", score: 650), BenchLiveLeg(id: "gpu", name: "GPU", score: 650))
        XCTAssertNotEqual(BenchLiveLeg(id: "gpu", name: "GPU", score: 650), BenchLiveLeg(id: "gpu", name: "GPU", score: 651))
    }
}
