import XCTest
@testable import Blip

/// The DEBUG-only UI-test plumbing: off under unit tests (no -UITestMode argument), and the
/// canned bench run the UI tests drive behaves like a real run through the engine's state.
@MainActor
final class UITestModeTests: XCTestCase {
    func testUITestModeIsOffWithoutTheLaunchArgument() {
        XCTAssertFalse(UITestMode.isActive)
        XCTAssertFalse(UITestMode.isSeeded)
        XCTAssertNil(UITestMode.value("UITestScenario"))
        XCTAssertFalse(UITestMode.flag("UITestRecommendation"))
        XCTAssertFalse(BlipUITestFixtures.isIsolatedHost, "unit tests are hosted by the shipping bundle id")
    }

    func testBenchStubWalksEveryLegAndRecordsTheCannedResult() async throws {
        let defaults = Fixtures.scratchDefaults("uitest-bench-ok")
        let engine = BenchEngine(defaults: defaults)
        engine.startUITestRun(profile: .full)
        try await waitUntil { engine.lastResult != nil }
        XCTAssertEqual(engine.lastResult?.composite, 1388)
        XCTAssertEqual(engine.liveLegs.map(\.id), ["single", "multi", "memory", "gpu", "neural"])
        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.progress, 1)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.history.count, 1)
        XCTAssertEqual(BenchHistory.load(defaults: defaults).last?.composite, 1388)
    }

    func testBenchStubCancelledMidRunRecordsNothing() async throws {
        let defaults = Fixtures.scratchDefaults("uitest-bench-cancel")
        let engine = BenchEngine(defaults: defaults)
        engine.startUITestRun(profile: .quick)
        try await waitUntil { !engine.liveLegs.isEmpty }
        engine.cancel()
        try await waitUntil { engine.phase == .idle }
        XCTAssertNil(engine.lastResult)
        XCTAssertTrue(engine.history.isEmpty)
        XCTAssertTrue(BenchHistory.load(defaults: defaults).isEmpty)
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
