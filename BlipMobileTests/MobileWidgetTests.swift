import XCTest
import SwiftUI
import WidgetKit
@testable import BlipMobile

// The widget file is compiled into this bundle (BLIP_WIDGET_TESTS) so its providers and views
// run for real: entries come from the same App Group store the app writes, timelines refresh
// on the documented cadence, and every view renders in every family it ships in.

@MainActor
final class MobileWidgetTests: XCTestCase {

    private let storeKeys = ["widget.device", "widget.speed", "benchHistory.v1"]

    override func setUp() async throws {
        // Snapshot + clear the keys the providers read; restore afterwards (the store is the
        // simulator's real App Group suite).
        let store = MobileSharedStore.defaults
        let keys = storeKeys
        var saved: [String: Any] = [:]
        for k in keys { if let v = store.object(forKey: k) { saved[k] = v } }
        addTeardownBlock {
            let s = MobileSharedStore.defaults
            for k in keys { s.removeObject(forKey: k) }
            for (k, v) in saved { s.set(v, forKey: k) }
        }
        for k in keys { store.removeObject(forKey: k) }
    }

    private func result(profile: BenchProfile = .full, composite: Double = 1_300, date: Date = .now,
                        throttle: Double? = 0.9, gpu: Bool = true, neural: Bool = true) -> BenchResult {
        BenchResult(date: date, profile: profile,
                    singleCore: .init(name: "s", score: 700, results: []),
                    multiCore: .init(name: "m", score: 6_000, results: []),
                    memory: .init(name: "mem", score: 1_000, results: []),
                    gpu: gpu ? .init(name: "g", score: 650, results: []) : nil,
                    neural: neural ? .init(name: "n", score: 800, results: []) : nil,
                    throttleFactor: throttle, thermalSamples: [], composite: composite,
                    deviceModel: "iPhone18,1", osVersion: "iOS")
    }

    private func render<V: View>(_ view: V, family: WidgetFamily) throws -> CGSize {
        let size: CGSize = family == .systemSmall ? .init(width: 170, height: 170) : .init(width: 360, height: 170)
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "the widget view must render")
        return image.size
    }

    // MARK: Timeline plumbing

    func testWidgetTimelineRefreshesHalfAnHourAfterNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entry = StorageEntry(date: now, record: nil)
        let timeline = widgetTimeline(entry, now: now)
        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(String(describing: timeline.policy),
                       String(describing: TimelineReloadPolicy.after(now.addingTimeInterval(1800))))
        XCTAssertNotEqual(String(describing: timeline.policy),
                          String(describing: TimelineReloadPolicy.after(now.addingTimeInterval(60))))
    }

    // MARK: Bench

    func testBenchProviderReadsTheStoredHistory() {
        XCTAssertNil(BenchProvider().load().result, "nothing recorded yet")

        let d = MobileSharedStore.defaults
        BenchHistory.append(result(composite: 1_500, date: Date(timeIntervalSince1970: 10)), defaults: d)
        BenchHistory.append(result(profile: .quick, composite: 900, date: Date(timeIntervalSince1970: 20)), defaults: d)
        let entry = BenchProvider().load()
        XCTAssertEqual(entry.result?.composite, 900, "the latest run, quick or not")
        XCTAssertEqual(entry.best, 1_500, "best only counts full runs")
    }

    func testBenchPlaceholderCarriesSampleData() {
        let entry = BenchProvider.placeholderEntry
        XCTAssertEqual(entry.result?.composite, 1300)
        XCTAssertEqual(entry.best, 1300)
    }

    func testBenchRegressionPercent() {
        let r = result(composite: 1_170)
        XCTAssertEqual(BenchWidgetView.regressionPercent(result: r, best: 1_300), -10)
        XCTAssertNil(BenchWidgetView.regressionPercent(result: result(composite: 1_300), best: 1_300), "at the best")
        XCTAssertNil(BenchWidgetView.regressionPercent(result: result(composite: 1_400), best: 1_300), "above the best")
        XCTAssertNil(BenchWidgetView.regressionPercent(result: result(profile: .quick, composite: 100), best: 1_300),
                     "quick runs are not comparable to the full best")
        XCTAssertNil(BenchWidgetView.regressionPercent(result: r, best: nil))
        XCTAssertNil(BenchWidgetView.regressionPercent(result: r, best: 0))
    }

    func testBenchViewRendersEmptyAndFilledInBothFamilies() throws {
        let empty = BenchEntry(date: .now, result: nil, best: nil)
        let slow = BenchEntry(date: .now, result: result(composite: 1_000, gpu: false, neural: false), best: 1_300)
        let fast = BenchEntry(date: .now, result: result(throttle: nil), best: 1_300)
        for family in [WidgetFamily.systemSmall, .systemMedium] {
            for entry in [empty, slow, fast] {
                let size = try render(BenchWidgetView(entry: entry, familyOverride: family), family: family)
                XCTAssertGreaterThan(size.width, 0)
            }
        }
    }

    // MARK: Storage

    func testStorageProviderReadsTheDeviceRecord() throws {
        XCTAssertNil(StorageProvider().load().record)
        var snapshot = DeviceSnapshot()
        snapshot.storageTotal = 512
        snapshot.storageFree = 128
        MobileSharedStore.write(device: snapshot)
        let record = try XCTUnwrap(StorageProvider().load().record)
        XCTAssertEqual(record.storageTotal, 512)
        XCTAssertEqual(record.storageFree, 128)
        XCTAssertEqual(StorageProvider.placeholderEntry.record?.storageFree, 128_000_000_000)
    }

    func testStorageViewRendersEveryState() throws {
        let empty = StorageEntry(date: .now, record: nil)
        let zero = StorageEntry(date: .now, record: .init(storageTotal: 0, storageFree: 0, thermalState: 0,
                                                          batteryLevel: nil, date: .now))
        let nearlyFull = StorageEntry(date: .now, record: .init(storageTotal: 1_000, storageFree: 20, thermalState: 0,
                                                                batteryLevel: 0.5, date: .now))
        for entry in [empty, zero, nearlyFull, StorageProvider.placeholderEntry] {
            _ = try render(StorageWidgetView(entry: entry), family: .systemSmall)
        }
    }

    // MARK: Speed

    func testSpeedProviderReadsTheLastSpeedRecord() throws {
        XCTAssertNil(SpeedProvider().load().record)
        MobileSharedStore.write(speed: .init(downMbps: 410, upMbps: 38, date: Date(timeIntervalSince1970: 5),
                                             interface: "Wi-Fi", pingMs: 9, loadedPingMs: 25))
        let record = try XCTUnwrap(SpeedProvider().load().record)
        XCTAssertEqual(record.downMbps, 410)
        XCTAssertEqual(record.upMbps, 38)
        XCTAssertEqual(record.interface, "Wi-Fi")
        XCTAssertEqual(SpeedProvider.placeholderEntry.record?.downMbps, 940)
    }

    func testSpeedViewRendersWithAndWithoutOptionalFields() throws {
        let bare = SpeedEntry(date: .now, record: .init(downMbps: 100, upMbps: nil, date: .now, interface: "Cellular"))
        let pingOnly = SpeedEntry(date: .now, record: .init(downMbps: 100, upMbps: 20, date: .now, interface: "Wi-Fi",
                                                           pingMs: 12, loadedPingMs: nil))
        for entry in [SpeedEntry(date: .now, record: nil), bare, pingOnly, SpeedProvider.placeholderEntry] {
            _ = try render(SpeedWidgetView(entry: entry), family: .systemMedium)
        }
    }

    func testWidgetBackgroundAndConfigurationsConstruct() {
        _ = BlipWidgetBackground(tint: .teal).body
        XCTAssertNotNil(BlipBenchWidget().body)
        XCTAssertNotNil(BlipStorageWidget().body)
        XCTAssertNotNil(BlipSpeedWidget().body)
    }
}
