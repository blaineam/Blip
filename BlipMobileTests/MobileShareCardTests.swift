import XCTest
import SwiftUI
@testable import BlipMobile

// The share-sheet payloads: ImageRenderer cards and their companion text, over the result
// shapes the app can produce (full / quick, with and without GPU, Neural, throttling, curves).

@MainActor
final class MobileShareCardTests: XCTestCase {

    private func bench(profile: BenchProfile = .full, gpu: Bool = true, neural: Bool = true,
                       throttle: Double? = 0.8, composite: Double = 1_342.4) -> BenchResult {
        BenchResult(date: Date(timeIntervalSince1970: 1_760_000_000), profile: profile,
                    singleCore: .init(name: "s", score: 711, results: []),
                    multiCore: .init(name: "m", score: 6_335, results: []),
                    memory: .init(name: "mem", score: 1_060, results: []),
                    gpu: gpu ? .init(name: "g", score: 658, results: []) : nil,
                    neural: neural ? .init(name: "n", score: 800, results: []) : nil,
                    throttleFactor: throttle, thermalSamples: [], composite: composite,
                    deviceModel: "iPhone18,1", osVersion: "iOS")
    }

    private func speed(up: Double? = 48.6, ping: Double? = 12.2, loaded: Double? = 140, curve: Bool = true) -> MobileSpeedResult {
        var r = MobileSpeedResult(downMbps: 512.4, upMbps: up, pingMs: ping,
                                  date: Date(timeIntervalSince1970: 1_760_000_000),
                                  interface: "Wi-Fi", source: "192.168.1.50")
        r.loadedPingMs = loaded
        if curve {
            r.downCurve = (0..<40).map { Double($0) * 13 }
            r.upCurve = (0..<30).map { Double($0) * 1.6 }
        }
        return r
    }

    // MARK: Images

    func testBenchCardRendersAtTheShareWidth() throws {
        let image = try XCTUnwrap(ShareCard.render(BenchShareCardView(result: bench())))
        XCTAssertEqual(image.size.width, 700, accuracy: 0.5)
        XCTAssertEqual(image.scale, 3)
        XCTAssertGreaterThan(image.size.height, 100)
        XCTAssertNotNil(image.pngData(), "the image encodes for the share sheet")
    }

    func testBenchCardVariantsRenderDifferentContent() throws {
        let full = try XCTUnwrap(ShareCard.render(BenchShareCardView(result: bench())))
        let sparse = try XCTUnwrap(ShareCard.render(
            BenchShareCardView(result: bench(profile: .quick, gpu: false, neural: false, throttle: nil))))
        let steady = try XCTUnwrap(ShareCard.render(BenchShareCardView(result: bench(throttle: 1.0))))
        XCTAssertNotEqual(full.pngData(), sparse.pngData())
        XCTAssertNotEqual(full.pngData(), steady.pngData(), "20% lost vs none renders differently")
    }

    func testSpeedCardGrowsWhenItCarriesACurve() throws {
        let plain = try XCTUnwrap(ShareCard.render(SpeedShareCardView(result: speed(curve: false))))
        let curved = try XCTUnwrap(ShareCard.render(SpeedShareCardView(result: speed(curve: true))))
        XCTAssertGreaterThan(curved.size.height, plain.size.height)
        XCTAssertEqual(curved.size.width, 700, accuracy: 0.5)
        // A download-only result with no latency still renders.
        XCTAssertNotNil(ShareCard.render(SpeedShareCardView(result: speed(up: nil, ping: nil, loaded: nil, curve: false))))
    }

    func testRenderHonoursACustomWidth() throws {
        let image = try XCTUnwrap(ShareCard.render(SpeedShareCardView(result: speed()), width: 500))
        XCTAssertEqual(image.size.width, 500, accuracy: 0.5)
    }

    // MARK: Text

    func testBenchTextVariants() {
        let quick = ShareCard.benchText(bench(profile: .quick, gpu: false, neural: false, throttle: nil))
        let lines = quick.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "Composite 1342 (quick run)")
        XCTAssertEqual(lines[2], "Single-core 711 · All cores 6335 · Memory 1060")
        XCTAssertEqual(lines.last, "Measured with Blip · wemiller.com/apps/blip")
        XCTAssertEqual(lines.count, 4, "no throttle line without a sustained phase")

        let steady = ShareCard.benchText(bench(throttle: 1.0))
        XCTAssertTrue(steady.contains("No throttling under sustained load"))
        XCTAssertTrue(steady.contains("GPU 658 · Neural 800"))
    }

    func testSpeedTextOmitsMissingFields() {
        let text = ShareCard.speedText(speed(up: nil, ping: nil, loaded: nil, curve: false))
        XCTAssertTrue(text.hasPrefix("Network speed — 512 Mbps down\n"), text)
        XCTAssertFalse(text.contains("Mbps up"))
        XCTAssertFalse(text.contains("idle"))
        XCTAssertTrue(text.contains("via 192.168.1.50 on Wi-Fi"))
        XCTAssertTrue(text.hasSuffix("Measured with Blip · wemiller.com/apps/blip"))
    }

    func testSharePayloadCarriesImageAndText() {
        let image = ShareCard.render(SpeedShareCardView(result: speed())) ?? UIImage()
        let payload = SharePayload(image: image, text: ShareCard.speedText(speed()))
        XCTAssertTrue(payload.text.contains("Network speed"))
        XCTAssertEqual(payload.image.size, image.size)
    }
}
