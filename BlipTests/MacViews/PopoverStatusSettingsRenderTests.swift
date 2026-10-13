import XCTest
import SwiftUI
@testable import Blip

/// The menu-bar item, the popover and Settings hosted with a fixture-fed SystemMonitor
/// (never started, so no polling, no helper, no hardware reads).
@MainActor
final class PopoverStatusSettingsRenderTests: XCTestCase {

    private func monitor(_ edit: (inout SystemSnapshot) -> Void = { _ in }) -> SystemMonitor {
        let m = SystemMonitor(defaults: Fixtures.scratchDefaults("psr-\(UUID().uuidString)"))
        var s = Fixtures.snapshot()
        s.system.macModel = "MacBook Pro"; s.system.macOSVersion = "macOS 27.0"
        s.topProcessesByCPU = [Blip.ProcessInfo(id: 9, name: "Rogue", cpu: 95, memory: 1, icon: nil)]
        edit(&s)
        m.snapshot = s
        m.recommendations = RecommendationsEngine.analyze(s)
        return m
    }

    private func engine() -> BenchEngine {
        BenchEngine(defaults: Fixtures.scratchDefaults("psr-bench-\(UUID().uuidString)"))
    }

    // MARK: Status item

    func testStatusItemRendersEveryLayoutAndToggleCombination() {
        let m = monitor()
        var sizes: [String: CGSize] = [:]
        for layout in ["horizontal", "stacked"] {
            for labels in [true, false] {
                for values in [true, false] {
                    let prefs: [String: Any] = ["menuBarLayout": layout, "showMeasurementLabels": labels,
                                                "showValueLabels": values, "showGPU": true]
                    sizes["\(layout)-\(labels)-\(values)"] = ViewHost.smoke(StatusItemView(monitor: m), prefs: prefs)
                }
            }
        }
        XCTAssertGreaterThan(sizes["horizontal-true-true"]!.width, sizes["horizontal-false-false"]!.width,
                             "labels and values make the item wider")
    }

    func testStatusItemMetricVisibilityAndColourModes() {
        let m = monitor()
        let all = ViewHost.smoke(StatusItemView(monitor: m))
        let none = ViewHost.smoke(StatusItemView(monitor: m),
                                  prefs: ["showCPU": false, "showMemory": false, "showDisk": false,
                                          "showNetworkDot": false])
        XCTAssertGreaterThan(all.width, none.width)
        for accent in ["", "monochrome", "3A7BD5", "bogus"] {
            ViewHost.smoke(StatusItemView(monitor: m), prefs: ["accentColorOverride": accent])
            ViewHost.smoke(StatusItemView(monitor: m), prefs: ["accentColorOverride": accent, "colorizeUtilization": false])
        }
        let hot = monitor { $0.cpu.totalUsage = 99; $0.memory.pressureLevel = 4; $0.network.downloadSpeed = 0 }
        ViewHost.smoke(StatusItemView(monitor: hot))
        ViewHost.smoke(StatusItemView(monitor: monitor { $0.network = NetworkStats() }))
    }

    // MARK: Popover

    func testPopoverRendersAllRowsAndFooter() {
        let m = monitor()
        let size = ViewHost.smoke(PopoverView(monitor: m, benchEngine: engine()))
        XCTAssertGreaterThan(size.height, 200)
        let noBattery = monitor { $0.battery.isPresent = false; $0.system.macModel = "" }
        let smaller = ViewHost.smoke(PopoverView(monitor: noBattery, benchEngine: engine()))
        XCTAssertLessThan(smaller.height, size.height, "no battery row and no model footer")
    }

    func testPopoverRecommendationBannerTogglesWithPreference() {
        let m = monitor()
        XCTAssertFalse(m.recommendations.isEmpty, "fixture is built to trip a rule")
        let on = ViewHost.smoke(PopoverView(monitor: m, benchEngine: engine()))
        let off = ViewHost.smoke(PopoverView(monitor: m, benchEngine: engine()), prefs: ["showRecommendations": false])
        XCTAssertGreaterThan(on.height, off.height)
        for sev in [Recommendation.Severity.info, .warning, .critical] {
            m.recommendations = [Recommendation(id: "x\(sev.rawValue)", severity: sev, icon: "bolt", title: "T", detail: "D")]
            ViewHost.smoke(PopoverView(monitor: m, benchEngine: engine()))
        }
    }

    func testPopoverPinInlineStylesAndCallbacks() {
        let m = monitor()
        ViewHost.smoke(PopoverView(monitor: m, onHoverSection: { _ in }, benchEngine: engine(),
                                   speedHistory: [NetSpeedResult(downMbps: 100, upMbps: 20, timestamp: Date())],
                                   onOpenSettings: {}, onOpenSupport: {}, onTogglePin: {}),
                       prefs: ["popoverPinned": true])
        ViewHost.smoke(PopoverView(monitor: m, benchEngine: engine(),
                                   inlineDetail: { _ in AnyView(Text("detail")) }),
                       prefs: [DetailPanelStyle.key: "inline"])
    }

    func testPopoverBenchRowShowsRunningAndLastScore() {
        let suite = Fixtures.scratchDefaults("psr-bench-hist")
        BenchHistory.append(BenchResult(date: Date(), profile: .full,
            singleCore: .init(name: "s", score: 700, results: []), multiCore: .init(name: "m", score: 6000, results: []),
            memory: .init(name: "mem", score: 1000, results: []), gpu: nil, neural: nil, throttleFactor: nil,
            thermalSamples: [], composite: 1234, deviceModel: "t", osVersion: "t"), defaults: suite)
        let e = BenchEngine(defaults: suite)
        XCTAssertEqual(e.lastResult?.composite, 1234)
        ViewHost.smoke(PopoverView(monitor: monitor(), benchEngine: e))
        ViewHost.smoke(BenchDetailPanel(engine: e))
        e.start(profile: .quick)
        XCTAssertTrue(e.isRunning)
        ViewHost.smoke(PopoverView(monitor: monitor(), benchEngine: e))
        ViewHost.smoke(BenchDetailPanel(engine: e))
        ViewHost.smoke(BenchRunningRows(engine: e))
        e.cancel()
    }

    func testBenchPanelWithNoHistory() {
        let e = engine()
        XCTAssertNil(e.lastResult)
        ViewHost.smoke(BenchDetailPanel(engine: e))
    }

    func testPopoverSectionsAreAllNamed() {
        XCTAssertEqual(PopoverSection.allCases.count, 9)
        XCTAssertEqual(Set(PopoverSection.allCases.map(\.rawValue)).count, 9)
    }

    // MARK: Settings

    func testSettingsRendersFirstTabWithAndWithoutCollaborators() {
        let withMonitor = ViewHost.smoke(SettingsView(helperClient: nil, monitor: monitor()), width: 520, prefs: [:])
        XCTAssertGreaterThan(withMonitor.height, 100)
        ViewHost.smoke(SettingsView(), width: 520)
        ViewHost.smoke(SettingsView(helperClient: HelperClient(portFileURL: URL(fileURLWithPath: "/nonexistent/blip.port")),
                                    monitor: monitor()), width: 520,
                       prefs: ["accentColorOverride": "3A7BD5", "menuBarLayout": "stacked", "geoipAutoUpdate": true,
                               DetailPanelStyle.key: "inline"])
    }
}
