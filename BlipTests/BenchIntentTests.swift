import XCTest
@testable import Blip

// The intent surface Soren drives. Plumbing asserts use an injected fake (fast, deterministic);
// one end-to-end case runs the REAL quick profile through the intent, which is the exact
// invocation `soren` and Shortcuts use in the field.

final class BenchIntentTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run {
            AppIntentsEnvironment.benchRunner = { profile in
                await BenchEngine.runOnce(profile: profile, thermal: NullThermalSource())
            }
        }
        try await super.tearDown()
    }

    @MainActor
    func testIntentReturnsCompositeAndSummarizesCategories() async throws {
        AppIntentsEnvironment.benchRunner = { profile in
            XCTAssertEqual(profile, .quick)
            return BenchResult(
                date: Date(), profile: .quick,
                singleCore: .init(name: "Single-core", score: 1234, results: []),
                multiCore: .init(name: "All cores", score: 8000, results: []),
                memory: .init(name: "Memory", score: 900, results: []),
                gpu: .init(name: "GPU", score: 2500, results: []),
                neural: nil,
                throttleFactor: 0.82, thermalSamples: [],
                composite: 2100.24, deviceModel: "test", osVersion: "test")
        }
        let intent = RunBenchmarkIntent()
        intent.profile = .quick
        let result = try await intent.perform()
        XCTAssertEqual(result.value, 2100.2)
    }

    @MainActor
    func testIntentSurfacesCancellationAsAFailure() async {
        AppIntentsEnvironment.benchRunner = { _ in nil }
        let intent = RunBenchmarkIntent()
        intent.profile = .quick
        do {
            _ = try await intent.perform()
            XCTFail("a nil result must throw, not pretend to score")
        } catch { /* expected */ }
    }

    @MainActor
    func testIntentEndToEndOnRealHardwareQuickProfile() async throws {
        // The real thing, exactly as Soren invokes it. ~6 s of CPU/GPU on the test host.
        let intent = RunBenchmarkIntent()
        intent.profile = .quick
        let result = try await intent.perform()
        let score = try XCTUnwrap(result.value)
        XCTAssertGreaterThan(score, 0)
    }
}
