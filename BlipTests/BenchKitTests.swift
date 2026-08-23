import XCTest
@testable import Blip

// BenchKit — the Soren-facing gate. These run the REAL workloads at tiny budgets (tenths of a
// second): every code path executes on real hardware in every unit run, which is exactly the
// per-user-story automated coverage CONTRIBUTING.md demands of the feature itself.

final class BenchKitTests: XCTestCase {

    private let tinyBudget = 0.15

    // MARK: - Workloads produce sane throughputs

    func testCPUWorkloadsProducepositiveThroughput() {
        for r in BenchWorkloads.cpuMix(seconds: tinyBudget * 4, cancelled: { false }) {
            XCTAssertGreaterThan(r.value, 0, "\(r.id) reported zero throughput")
        }
    }

    func testMemoryBandwidthIsPlausible() {
        let r = BenchWorkloads.memoryBandwidth(seconds: tinyBudget, cancelled: { false })
        // Any machine that can run these tests moves more than 1 GB/s and less than 10 TB/s.
        XCTAssertGreaterThan(r.value, 1)
        XCTAssertLessThan(r.value, 10_000)
    }

    func testMemoryLatencyIsPlausible() {
        let r = BenchWorkloads.memoryLatency(seconds: tinyBudget, cancelled: { false })
        // DRAM round-trips live between 20 ns and 1 µs on everything Blip supports.
        XCTAssertGreaterThan(r.value, 5)
        XCTAssertLessThan(r.value, 1_000)
    }

    func testGPUMatmulRunsWhereMetalExists() throws {
        guard let r = BenchGPU.matmul(seconds: tinyBudget, cancelled: { false }) else {
            throw XCTSkip("no Metal/MPS device on this runner — the score omits GPU by design")
        }
        XCTAssertGreaterThan(r.value, 1, "a working GPU does more than 1 GFLOPS")
    }

    // MARK: - Cancellation

    func testCancellationStopsWorkloadsQuickly() {
        let start = CFAbsoluteTimeGetCurrent()
        _ = BenchWorkloads.sha256(seconds: 30, cancelled: { true })   // pre-cancelled
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 2,
                          "a cancelled workload must return promptly, not run its full budget")
    }

    // MARK: - Score math

    func testCompositeIsGeometricMeanTimes1000() {
        let results = [
            WorkloadResult(id: "cpu.sha256", value: BenchReference.unit["cpu.sha256"]!, unit: .mbPerSec),
            WorkloadResult(id: "cpu.lzfse", value: BenchReference.unit["cpu.lzfse"]! * 4, unit: .mbPerSec),
        ]
        // norms = [1, 4] → geomean 2 → 2000.
        XCTAssertEqual(BenchScore.composite(results), 2000, accuracy: 0.001)
    }

    func testLatencyScoresInvert() {
        let ref = BenchReference.unit["mem.latency"]!
        let half = WorkloadResult(id: "mem.latency", value: ref / 2, unit: .nsPerAccess)
        // Half the reference latency = twice the score.
        XCTAssertEqual(BenchScore.normalized(half)!, 2, accuracy: 0.001)
    }

    func testUnknownAndZeroWorkloadsDropOutInsteadOfZeroing() {
        let results = [
            WorkloadResult(id: "cpu.sha256", value: BenchReference.unit["cpu.sha256"]!, unit: .mbPerSec),
            WorkloadResult(id: "not.a.thing", value: 123, unit: .mbPerSec),
            WorkloadResult(id: "cpu.fft", value: 0, unit: .fftPerSec),
        ]
        XCTAssertEqual(BenchScore.composite(results), 1000, accuracy: 0.001,
                       "unknown ids and zero values must not drag the mean to zero")
    }

    func testOverallSkipsMissingCategories() {
        let cat = BenchCategoryScore(name: "CPU", score: 1500, results: [])
        XCTAssertEqual(BenchScore.overall([cat, nil]), 1500, accuracy: 0.001)
    }

    // MARK: - The engine end-to-end (quick profile, the Soren path)

    @MainActor
    func testQuickProfileProducesACompleteResult() async {
        let result = await BenchEngine.runOnce(profile: .quick)
        let r = try! XCTUnwrap(result, "quick profile must produce a result on a healthy machine")
        XCTAssertGreaterThan(r.composite, 0)
        XCTAssertGreaterThan(r.singleCore.score, 0)
        XCTAssertGreaterThan(r.multiCore.score, r.singleCore.score,
                             "all cores together must out-score one core")
        XCTAssertGreaterThan(r.memory.score, 0)
        XCTAssertNil(r.throttleFactor, "quick profile has no sustained phase")
        XCTAssertEqual(r.profile, .quick)
        XCTAssertFalse(r.deviceModel.isEmpty)
    }

    // MARK: - History

    func testHistoryAppendsCapsAndTracksPersonalBest() {
        let suite = UserDefaults(suiteName: "benchkit-tests-\(UUID().uuidString)")!
        func fake(_ score: Double, profile: BenchProfile) -> BenchResult {
            BenchResult(date: Date(), profile: profile,
                        singleCore: .init(name: "s", score: score, results: []),
                        multiCore: .init(name: "m", score: score, results: []),
                        memory: .init(name: "mem", score: score, results: []),
                        gpu: nil, neural: nil, throttleFactor: nil, thermalSamples: [],
                        composite: score, deviceModel: "test", osVersion: "test")
        }
        for i in 0..<(BenchHistory.maxEntries + 5) {
            BenchHistory.append(fake(Double(i), profile: .full), defaults: suite)
        }
        BenchHistory.append(fake(9999, profile: .quick), defaults: suite)   // quick ≠ a record
        let all = BenchHistory.load(defaults: suite)
        XCTAssertEqual(all.count, BenchHistory.maxEntries)
        XCTAssertEqual(BenchHistory.personalBest(defaults: suite),
                       Double(BenchHistory.maxEntries + 4),
                       "personal best considers FULL runs only — quick is QA, not a measurement")
    }
}
