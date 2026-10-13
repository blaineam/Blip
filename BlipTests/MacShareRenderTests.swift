import XCTest
import SwiftUI
import AppKit
@testable import Blip

// The share cards are drawn with ImageRenderer from the same views the iOS app ships; the
// snapshot export also writes a Markdown file. Text building lives in FormattingAndShareTests;
// this covers the rendering and file side, plus the formatting helpers behind the Mac panels.

@MainActor
final class MacShareRenderTests: XCTestCase {

    private func bench(gpu: Bool, neural: Bool, throttle: Double?) -> BenchResult {
        BenchResult(date: Date(timeIntervalSince1970: 1_800_000_000), profile: throttle == nil ? .quick : .full,
                    singleCore: .init(name: "s", score: 690, results: []),
                    multiCore: .init(name: "m", score: 6_300, results: []),
                    memory: .init(name: "mem", score: 1_000, results: []),
                    gpu: gpu ? .init(name: "g", score: 650, results: []) : nil,
                    neural: neural ? .init(name: "n", score: 800, results: []) : nil,
                    throttleFactor: throttle, thermalSamples: [], composite: 1_299.5,
                    deviceModel: "Mac15,3", osVersion: "macOS")
    }

    func testBenchCardsRenderAtTwiceTheRequestedWidthForEveryVariant() throws {
        let variants: [(Bool, Bool, Double?)] = [(true, true, 0.8), (false, false, 1.0), (false, false, nil), (true, false, 0.5)]
        for (gpu, neural, throttle) in variants {
            let view = MacBenchShareCardView(result: bench(gpu: gpu, neural: neural, throttle: throttle), deviceName: "MacBook Pro")
            let image = try XCTUnwrap(MacShareCard.render(view, width: 400), "gpu \(gpu) neural \(neural) throttle \(String(describing: throttle))")
            XCTAssertEqual(image.size.width, 400, accuracy: 1)
            XCTAssertGreaterThan(image.size.height, 100)
            XCTAssertNotNil(image.tiffRepresentation)
        }
    }

    func testSpeedCardsRenderWithAndWithoutCurves() throws {
        var full = NetSpeedResult(downMbps: 940, upMbps: 38, timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        full.pingMs = 9; full.loadedPingMs = 180
        full.downCurve = [100, 400, 900, 940]; full.upCurve = [10, 30, 38]
        let bare = NetSpeedResult(downMbps: 50, upMbps: nil, timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        for result in [full, bare] {
            let image = try XCTUnwrap(MacShareCard.render(MacSpeedShareCardView(result: result)))
            XCTAssertEqual(image.size.width, 700, accuracy: 1, "default card width")
        }
    }

    func testSnapshotPayloadWritesTheMarkdownToAFile() throws {
        let snapshot = Fixtures.snapshot()
        let url = MacSnapshotExport.file(snapshot, speedHistory: [])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Blip-Snapshot-"))
        XCTAssertEqual(url.pathExtension, "md")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("## CPU"))
        XCTAssertTrue(text.hasSuffix("wemiller.com/apps/blip/)_\n"))
        // The lazy payload carries the same inputs it will render on demand.
        let payload = SnapshotFilePayload(snapshot: snapshot, speedHistory: [])
        XCTAssertEqual(payload.snapshot.cpu.totalUsage, 42.5)
    }

    func testShareHoldNotificationsHaveStableNames() {
        XCTAssertEqual(Notification.Name.blipShareHoldBegan.rawValue, "blipShareHoldBegan")
        XCTAssertEqual(Notification.Name.blipShareHoldEnded.rawValue, "blipShareHoldEnded")
    }

    func testShareButtonCoordinatorBuildsItsItemsLazily() {
        var built = 0
        let coordinator = MacShareButton.Coordinator(makeItems: { built += 1; return ["caption"] })
        XCTAssertEqual(built, 0, "nothing is rendered until the user clicks")
        XCTAssertEqual(coordinator.makeItems().count, 1)
        XCTAssertEqual(built, 1)
    }
}
