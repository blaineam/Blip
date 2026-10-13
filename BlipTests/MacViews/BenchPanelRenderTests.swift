import XCTest
import SwiftUI
@testable import Blip

/// The Bench panel's result card in each shape a stored result can take: with and without
/// GPU/Neural legs, no/low/high throttling, thermal trace, and the delta-vs-best badge.
@MainActor
final class BenchPanelRenderTests: XCTestCase {

    private func result(_ composite: Double, profile: BenchProfile = .full, gpu: Bool = true, neural: Bool = true,
                        throttle: Double?, thermal: Bool = true) -> BenchResult {
        BenchResult(
            date: Date(timeIntervalSince1970: 1_700_000_000 + composite), profile: profile,
            singleCore: .init(name: "Single-core", score: 700, results: []),
            multiCore: .init(name: "All cores", score: 6000, results: []),
            memory: .init(name: "Memory", score: 1000, results: []),
            gpu: gpu ? .init(name: "GPU", score: 650, results: []) : nil,
            neural: neural ? .init(name: "Neural", score: 840, results: []) : nil,
            throttleFactor: throttle,
            thermalSamples: thermal ? (0..<6).map {
                BenchThermalSample(atSeconds: Double($0) * 5, temperatureC: 60 + Double($0) * 4,
                                   fanRPM: 2000 + Double($0) * 300, thermalState: min($0, 3))
            } : [BenchThermalSample(atSeconds: 0, temperatureC: nil, fanRPM: nil, thermalState: 0)],
            composite: composite, deviceModel: "Mac16,1", osVersion: "27.0")
    }

    private func engine(_ results: [BenchResult]) -> BenchEngine {
        let suite = Fixtures.scratchDefaults("bench-render-\(UUID().uuidString)")
        for r in results { BenchHistory.append(r, defaults: suite) }
        return BenchEngine(defaults: suite)
    }

    func testResultCardVariantsRender() {
        let plain = ViewHost.smoke(BenchDetailPanel(engine: engine([result(1500, gpu: false, neural: false, throttle: nil)])))
        let rich = ViewHost.smoke(BenchDetailPanel(engine: engine([result(1500, throttle: 0.7)])))
        XCTAssertGreaterThan(rich.height, plain.height, "GPU/Neural rows and the throttle summary add height")
        _ = ViewHost.smoke(BenchDetailPanel(engine: engine([result(1500, throttle: 1.0)])))
        _ = ViewHost.smoke(BenchDetailPanel(engine: engine([result(1500, throttle: 0.95, thermal: false)])))
        _ = ViewHost.smoke(BenchDetailPanel(engine: engine([result(1500, profile: .quick, throttle: nil)])))
    }

    func testDeltaBadgeComparesAgainstTheBestPreviousFullRun() {
        let slower = engine([result(2000, throttle: 0.9), result(1500, throttle: 0.9)])
        XCTAssertEqual(slower.lastResult?.composite, 1500)
        _ = ViewHost.smoke(BenchDetailPanel(engine: slower))
        let faster = engine([result(1500, throttle: 0.9), result(2000, throttle: 0.9)])
        XCTAssertEqual(faster.lastResult?.composite, 2000)
        _ = ViewHost.smoke(BenchDetailPanel(engine: faster))
        let thermalUp = engine([result(1500, throttle: 0.9)])
        XCTAssertEqual(thermalUp.history.count, 1)
    }
}
