//
//  BlipUITestSupport.swift
//  Blip
//
//  DEBUG-only fixtures for `-UITestMode` (see Shared/UITestMode.swift), used by the
//  BlipUITests XCUITest bundle against the BlipUITestHost app (own bundle id, so its
//  defaults are never the user's). Reuses the screenshot rig's fictional snapshot and
//  adds what the UI tests need on top: a GPU reading, an optional suggestion, a bench
//  history, and a canned RFC 5737 traceroute in place of the in-process ICMP runner.
//

#if DEBUG
import Foundation

enum BlipUITestFixtures {
    /// True only in the dedicated UI-test host — the guard that keeps the per-launch
    /// defaults wipe from ever touching the shipping bundle id's domain.
    static var isIsolatedHost: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".uitesthost") == true
    }

    /// Clean, isolated defaults for this launch, with inline (click-to-expand) details so
    /// tests read panels inside the window instead of chasing hover panels.
    static func resetDefaults() {
        guard isIsolatedHost, let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: id)
        UserDefaults.standard.set(DetailPanelStyle.inline.rawValue, forKey: DetailPanelStyle.key)
    }

    @MainActor
    static func load(into monitor: SystemMonitor) {
        monitor.loadDemoData()
        // The screenshot rig hides the helper-only GPU row; UI tests exercise it.
        monitor.snapshot.gpu.name = "Apple M4 Pro GPU"
        monitor.snapshot.gpu.utilization = 18
        if UITestMode.flag("UITestRecommendation") {
            // 4 GB of swap trips the real "mem-swap" rule, so dismiss/reset run the real engine.
            monitor.snapshot.memory.swapUsed = 4_000_000_000
            monitor.resetDismissedRecommendations()
        }
    }

    /// Seeds three bench runs (ending at a 1342 full run) into the isolated defaults.
    static func seedBench(defaults: UserDefaults = .standard) {
        guard UITestMode.isSeeded, BenchHistory.load(defaults: defaults).isEmpty else { return }
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        for (score, profile, daysAgo) in [(1246.0, BenchProfile.full, 14.0), (1301, .quick, 3), (1342, .full, 0.2)] {
            BenchHistory.append(BenchResult(
                date: base.addingTimeInterval(-daysAgo * 86_400), profile: profile,
                singleCore: .init(name: "Single-core", score: score * 0.53, results: []),
                multiCore: .init(name: "All cores", score: score * 4.72, results: []),
                memory: .init(name: "Memory", score: score * 0.79, results: []),
                gpu: .init(name: "GPU", score: score * 0.49, results: []),
                neural: .init(name: "Neural", score: score * 0.61, results: []),
                throttleFactor: profile == .full ? 0.95 : nil, thermalSamples: [],
                composite: score, deviceModel: "Mac16,7", osVersion: "macOS 15.0"),
                defaults: defaults)
        }
    }
}

/// Canned MTR session: hops appear one per poll interval, then keep "running" (as a real
/// MTR does) until stopped. RFC 5737 documentation addresses only.
@MainActor
final class UITestTraceStub {
    static let shared = UITestTraceStub()

    private static let route: [(String, Double)] = [
        ("192.168.1.1", 1.4), ("192.0.2.1", 4.1), ("192.0.2.44", 8.9), ("198.51.100.7", 19.6),
        ("*", 0), ("198.51.100.90", 31.2), ("203.0.113.12", 39.8), ("203.0.113.60", 44.0),
    ]

    private var startedAt: Date?
    private var running = false

    func start(host: String) {
        startedAt = Date()
        running = true
    }

    func stop() { running = false }

    func snapshot() -> (hops: [HelperTraceHop], running: Bool) {
        guard let startedAt else { return ([], false) }
        let visible = min(Self.route.count, 1 + Int(Date().timeIntervalSince(startedAt) / 0.15))
        let hops = Self.route.prefix(visible).enumerated().map { i, entry -> HelperTraceHop in
            let silent = entry.0 == "*"
            return HelperTraceHop(hop: i + 1, host: entry.0, sent: 10, recv: silent ? 0 : 10,
                                  lossPct: silent ? 100 : 0,
                                  lastMs: silent ? nil : entry.1, avgMs: silent ? nil : entry.1,
                                  bestMs: silent ? nil : entry.1 * 0.9, worstMs: silent ? nil : entry.1 * 1.2)
        }
        return (hops, running)
    }
}
#endif
