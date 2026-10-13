import XCTest
import Combine
import SwiftUI
@testable import BlipMobile

// Device stats sampling, the screenshot demo seed, the app's Shortcuts wiring, the chart
// views, and the speed tester's latency probes / failure handling against scripted ICMP.

@MainActor
final class MobileEnginesTests: XCTestCase {

    private func waitFor<P: Publisher>(_ publisher: P, timeout: TimeInterval = 60,
                                       _ condition: @escaping (P.Output) -> Bool) async where P.Failure == Never {
        let reached = expectation(description: "condition reached")
        reached.assertForOverFulfill = false
        let sub = publisher.sink { if condition($0) { reached.fulfill() } }
        await fulfillment(of: [reached], timeout: timeout)
        sub.cancel()
    }

    // MARK: DeviceStats

    func testLiveSampleFillsThePlausibleFieldsAndFeedsTheHistories() {
        let stats = DeviceStats()
        stats.sample()
        stats.sample()
        let s = stats.snapshot
        XCTAssertGreaterThan(s.memoryPhysical, 0)
        XCTAssertGreaterThan(s.coresTotal, 0)
        XCTAssertGreaterThan(s.storageTotal, 0)
        XCTAssertFalse(s.model.isEmpty)
        XCTAssertFalse(s.osVersion.isEmpty)
        XCTAssertTrue((0...3).contains(s.thermalState))
        XCTAssertGreaterThan(s.uptime, 0)
        XCTAssertNotNil(s.bootDate)
        XCTAssertGreaterThanOrEqual(s.cpuUsagePercent, 0)
        XCTAssertLessThanOrEqual(s.cpuUsagePercent, 100)
        XCTAssertGreaterThanOrEqual(stats.cpuHistory.values.count, 2)
        XCTAssertGreaterThanOrEqual(stats.thermalHistory.values.count, 2)
        // The widget record was refreshed by the sample.
        XCTAssertNotNil(MobileSharedStore.readDevice())
    }

    func testDemoModeOverlayWinsOverTheLiveValues() {
        let guardKeys = DefaultsGuard(standard: ["blip.demoSeed"])
        defer { guardKeys.restore() }
        UserDefaults.standard.set(true, forKey: "blip.demoSeed")
        let stats = DeviceStats()
        let s = stats.snapshot
        XCTAssertEqual(s.interfaceType, "Wi-Fi")
        XCTAssertEqual(s.localIPs, ["en0 192.0.2.24"], "documentation address, nobody's LAN")
        XCTAssertEqual(s.batteryLevel, 0.87)
        XCTAssertFalse(s.vpnActive)
    }

    func testDemoOverlayDiffersForPhoneAndPad() {
        var phone = DeviceSnapshot(); phone.model = "iPhone18,1"
        var pad = DeviceSnapshot(); pad.model = "iPad16,3"
        DeviceStats.applyDemoOverlay(&phone)
        DeviceStats.applyDemoOverlay(&pad)
        XCTAssertEqual(phone.memoryPhysical, 12 << 30)
        XCTAssertEqual(pad.memoryPhysical, 16 << 30)
        XCTAssertEqual(phone.storageTotal, 512_000_000_000)
        XCTAssertEqual(pad.storageTotal, 1_024_000_000_000)
        XCTAssertEqual(Double(phone.storageFree), Double(phone.storageTotal) * 0.38, accuracy: 1)
        XCTAssertGreaterThan(phone.storageOpportunistic, phone.storageFree)
    }

    func testUITestPinsAreStable() {
        var s = DeviceSnapshot(); s.model = "iPhone18,1"
        DeviceStats.applyUITestPins(&s)
        XCTAssertEqual(s.cpuUsagePercent, 23)
        XCTAssertEqual(s.thermalState, 0)
        XCTAssertEqual(s.coresTotal, 6)
        XCTAssertEqual(s.coresPerformance, 2)
        XCTAssertEqual(s.coresEfficiency, 4)
        XCTAssertEqual(s.uptime, 3 * 86_400 + 5 * 3_600 + 12 * 60)
        XCTAssertNil(s.bootDate)
        XCTAssertEqual(s.load1, 1.82)
        XCTAssertEqual(s.interfaceType, "Wi-Fi", "the demo overlay is part of the pins")
    }

    func testPublishedFixtureIsNotOverwrittenByLiveSampling() {
        let stats = DeviceStats()
        var fixture = DeviceSnapshot.fixture()
        fixture.cpuUsagePercent = 91
        stats.publishForTesting(fixture)
        stats.sample()
        XCTAssertEqual(stats.snapshot.cpuUsagePercent, 91)
        XCTAssertEqual(stats.snapshot.coresPerformance, 2)
    }

    func testModelIdentifierPrefersTheSimulatedDevice() {
        let identifier = DeviceStats.currentModelIdentifier()
        XCTAssertFalse(identifier.isEmpty)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            XCTAssertEqual(identifier, simulated)
        }
    }

    func testSnapshotDerivedValuesAtTheEdges() {
        var s = DeviceSnapshot()
        XCTAssertEqual(s.storagePercentUsed, 0, "an unknown volume reads 0%, not NaN")
        XCTAssertNil(s.bootUptime)
        s.storageTotal = 100; s.storageFree = 150
        XCTAssertEqual(s.storageUsed, 0, "free can't exceed total")
        for (state, label) in [(0, "Nominal"), (1, "Fair"), (2, "Serious"), (3, "Critical"), (9, "Critical")] {
            s.thermalState = state
            XCTAssertEqual(s.thermalLabel, label)
        }
        s.model = "iPad99,9"
        XCTAssertEqual(s.marketingName, "iPad99,9")
    }

    // MARK: Demo seed

    func testRequestedDemoSeedFillsBenchAndSpeedHistory() throws {
        let std = DefaultsGuard(standard: ["blip.demoSeed", "mobile.speed.source"],
                                shared: ["benchHistory.v1", "speed.history", "widget.speed"])
        defer { std.restore() }
        UserDefaults.standard.removeObject(forKey: "mobile.speed.source")
        MobileSharedStore.defaults.removeObject(forKey: "benchHistory.v1")
        MobileSharedStore.defaults.removeObject(forKey: "speed.history")
        UserDefaults.standard.set(true, forKey: "blip.demoSeed")

        DemoSeed.applyIfRequested()
        let bench = BenchHistory.load(defaults: MobileSharedStore.defaults)
        XCTAssertEqual(bench.count, 7)
        XCTAssertEqual(bench.last?.composite, 1_342, "the story ends at a strong full run")
        XCTAssertEqual(bench.filter { $0.profile == .full }.count, 4)
        XCTAssertTrue(bench.contains { $0.thermalSamples.count == 9 })

        let data = try XCTUnwrap(MobileSharedStore.defaults.data(forKey: "speed.history"))
        let speed = try JSONDecoder().decode([MobileSpeedResult].self, from: data)
        XCTAssertEqual(speed.count, 4)
        XCTAssertEqual(speed.last?.downMbps, 942, "oldest first, the latest run last")
        XCTAssertEqual(speed.last?.loadedPingMs, 29)
        XCTAssertEqual(speed.last?.downCurve?.count, 70)
        XCTAssertEqual(MobileSharedStore.readSpeed()?.downMbps, 942)

        // Seeding again must not duplicate anything.
        DemoSeed.applyIfRequested()
        XCTAssertEqual(BenchHistory.load(defaults: MobileSharedStore.defaults).count, 7)
    }

    func testCannedNetworkToolsDataIsInDocumentationSpace() {
        XCTAssertEqual(DemoSeed.pingSamples.count, 24)
        XCTAssertNil(DemoSeed.pingSamples[16].rttMs, "sample 17 is the lone timeout")
        XCTAssertEqual(DemoSeed.pingSamples.compactMap(\.rttMs).count, 23)
        XCTAssertEqual(DemoSeed.traceHops.map(\.ttl), Array(1...8))
        XCTAssertTrue(DemoSeed.traceHops.last?.isDestination ?? false)
        let allowedPrefixes = ["192.168.1.", "192.0.2.", "198.51.100.", "203.0.113."]
        for hop in DemoSeed.traceHops {
            guard let a = hop.address else { continue }
            XCTAssertTrue(allowedPrefixes.contains { a.hasPrefix($0) }, "\(a) is not documentation/private space")
        }
        // Every geolocated hop has a pin.
        for hop in DemoSeed.traceHops {
            guard let a = hop.address, !a.hasPrefix("192.168.") else { continue }
            XCTAssertNotNil(DemoSeed.geoTable[a], "no pin for \(a)")
        }
    }

    // MARK: App wiring (Shortcuts + routing)

    func testWidgetDeepLinksResolveToTabs() {
        XCTAssertEqual(BlipMobileApp.tab(for: URL(string: "blip://bench")!), .bench)
        XCTAssertEqual(BlipMobileApp.tab(for: URL(string: "blip://speed")!), .speed)
        XCTAssertEqual(BlipMobileApp.tab(for: URL(string: "blip://network")!), .network)
        XCTAssertEqual(BlipMobileApp.tab(for: URL(string: "blip://overview")!), .overview)
        XCTAssertEqual(BlipMobileApp.tab(for: URL(string: "blip:///network")!), .network, "path form")
        XCTAssertEqual(BlipMobileApp.tab(for: URL(string: "blip://nonsense")!), .overview)
    }

    func testRouterHonoursTheScreenshotRouteDefault() {
        let std = DefaultsGuard(standard: ["blip.route"])
        defer { std.restore() }
        UserDefaults.standard.set("network", forKey: "blip.route")
        XCTAssertEqual(BlipMobileApp.TabRouter().tab, .network)
        UserDefaults.standard.set("bogus", forKey: "blip.route")
        XCTAssertEqual(BlipMobileApp.TabRouter().tab, .overview)
        UserDefaults.standard.removeObject(forKey: "blip.route")
        XCTAssertEqual(BlipMobileApp.TabRouter().tab, .overview)
    }

    func testAppWiresShortcutsToTheLiveServices() async throws {
        let keys = DefaultsGuard(standard: ["mobile.speed.source", "mobile.speed.server", "blip.demoSeed"],
                                 shared: ["benchHistory.v1", "speed.history", "widget.speed"])
        let oldBench = MobileIntentsEnvironment.benchRunner
        let oldSpeed = MobileIntentsEnvironment.speedStarter
        let oldSnap = MobileIntentsEnvironment.snapshotProvider
        let oldTab = MobileIntentsEnvironment.tabSwitcher
        defer {
            keys.restore()
            MobileIntentsEnvironment.benchRunner = oldBench
            MobileIntentsEnvironment.speedStarter = oldSpeed
            MobileIntentsEnvironment.snapshotProvider = oldSnap
            MobileIntentsEnvironment.tabSwitcher = oldTab
        }
        UserDefaults.standard.removeObject(forKey: "blip.demoSeed")
        // A blank self-hosted server makes the speed starter fail fast instead of reaching the network.
        UserDefaults.standard.set(SpeedSource.custom.rawValue, forKey: "mobile.speed.source")
        UserDefaults.standard.removeObject(forKey: "mobile.speed.server")

        _ = BlipMobileApp()       // init → wireIntents()

        MobileIntentsEnvironment.speedStarter()
        MobileIntentsEnvironment.tabSwitcher("bench")
        MobileIntentsEnvironment.tabSwitcher("not-a-tab")    // unknown names are ignored

        let markdown = await MobileIntentsEnvironment.snapshotProvider()
        XCTAssertTrue(markdown.hasPrefix("# Blip Snapshot"), markdown)
        XCTAssertTrue(markdown.contains("## Storage"))

        let result = await MobileIntentsEnvironment.benchRunner(.quick)
        XCTAssertGreaterThan(try XCTUnwrap(result).composite, 0, "the shared engine ran a real quick profile")
    }

    // MARK: Charts

    private func image<V: View>(_ view: V) -> Data? {
        let r = ImageRenderer(content: view.frame(width: 240).background(Color.white))
        r.scale = 1
        return r.uiImage?.pngData()
    }

    func testChartsRenderForEmptyFlatAndVaryingData() {
        XCTAssertNotNil(image(Sparkline(values: [])))
        let flat = image(Sparkline(values: [5, 5, 5, 5]))
        let rising = image(Sparkline(values: [1, 2, 4, 8, 16], tint: .teal, height: 40, fixedDomain: 0...20))
        XCTAssertNotNil(flat)
        XCTAssertNotNil(rising)
        XCTAssertNotEqual(flat, rising)

        let calm = image(ThermalSteps(values: [0, 0, 0, 0]))
        let hot = image(ThermalSteps(values: [0, 1, 2, 3, 4]))
        XCTAssertNotNil(calm)
        XCTAssertNotEqual(calm, hot)

        XCTAssertNotNil(image(DualCurveChart(down: [], up: [])))
        XCTAssertNotEqual(image(DualCurveChart(down: [1, 5, 3], up: [])),
                          image(DualCurveChart(down: [1, 5, 3], up: [2, 2, 9])))
    }

    func testBenchHistoryChartShowsFullAndQuickRunsDifferently() {
        func run(_ composite: Double, _ profile: BenchProfile) -> BenchResult {
            BenchResult(date: .now, profile: profile,
                        singleCore: .init(name: "s", score: 1, results: []), multiCore: .init(name: "m", score: 1, results: []),
                        memory: .init(name: "mem", score: 1, results: []), gpu: nil, neural: nil, throttleFactor: nil,
                        thermalSamples: [], composite: composite, deviceModel: "x", osVersion: "x")
        }
        XCTAssertNotNil(image(BenchHistoryChart(history: [])))
        let full = image(BenchHistoryChart(history: [run(1_000, .full), run(1_200, .full)]))
        let quick = image(BenchHistoryChart(history: [run(1_000, .quick), run(1_200, .quick)]))
        XCTAssertNotNil(full)
        XCTAssertNotEqual(full, quick, "quick runs are drawn hollow")
    }

    // MARK: Speed tester: latency probes + failure handling

    private func speedSetUp() -> (restore: () -> Void, useServer: (String) -> Void) {
        let keys = DefaultsGuard(standard: ["mobile.speed.source", "mobile.speed.server"],
                                 shared: ["speed.history", "widget.speed"])
        for k in ["mobile.speed.source", "mobile.speed.server"] { UserDefaults.standard.removeObject(forKey: k) }
        MobileSharedStore.defaults.removeObject(forKey: "speed.history")
        MobileSharedStore.defaults.removeObject(forKey: "widget.speed")
        let oldSeconds = MobileSpeedTester.transferSeconds
        let oldProbes = MobileSpeedTester.latencyProbesEnabled
        let oldResolve = ICMPBackend.resolve
        let oldProbe = ICMPBackend.probe
        MobileSpeedTester.transferSeconds = (1.0, 1.0)
        MobileSpeedTester.latencyProbesEnabled = true
        ICMPBackend.resolve = { _ in sockaddr_in() }
        return ({
            keys.restore()
            MobileSpeedTester.transferSeconds = oldSeconds
            MobileSpeedTester.latencyProbesEnabled = oldProbes
            ICMPBackend.resolve = oldResolve
            ICMPBackend.probe = oldProbe
        }, { address in
            UserDefaults.standard.set(SpeedSource.custom.rawValue, forKey: "mobile.speed.source")
            UserDefaults.standard.set(address, forKey: "mobile.speed.server")
        })
    }

    func testRunRecordsIdleAndLoadedLatencyFromTheProbes() async throws {
        let (restore, useServer) = speedSetUp()
        defer { restore() }
        // Sequence numbers < 5000 are the idle burst; 5000+ are the probes during the download.
        ICMPBackend.probe = { _, _, seq, _ in ("192.0.2.1", seq < 5000 ? 11 : 87, true) }
        let server = try LoopbackHTTPServer(mode: .speedTest(downloadBytes: 4_000_000))
        defer { server.stop() }
        useServer(server.baseURL.absoluteString)

        let tester = MobileSpeedTester()
        tester.start(interface: "Wi-Fi")
        await waitFor(tester.$phase) { if case .failed = $0 { return true }; return $0 == .done }
        XCTAssertEqual(tester.phase, .done)
        let result = try XCTUnwrap(tester.lastResult)
        XCTAssertEqual(result.pingMs, 11, "median of the idle burst")
        XCTAssertEqual(result.loadedPingMs, 87, "median of the probes taken during the download")
        let widget = try XCTUnwrap(MobileSharedStore.readSpeed())
        XCTAssertEqual(widget.pingMs, 11)
        XCTAssertEqual(widget.loadedPingMs, 87)
        XCTAssertNil(tester.loadedProbeTask, "the probes stop when the download ends")
    }

    func testUnresolvablePingTargetJustMeansNoLatency() async throws {
        let (restore, useServer) = speedSetUp()
        defer { restore() }
        ICMPBackend.resolve = { host in throw ICMPSocketError.resolveFailed(host) }
        let server = try LoopbackHTTPServer(mode: .speedTest(downloadBytes: 2_000_000))
        defer { server.stop() }
        useServer(server.baseURL.absoluteString)
        let tester = MobileSpeedTester()
        tester.start(interface: "Wi-Fi")
        await waitFor(tester.$phase) { if case .failed = $0 { return true }; return $0 == .done }
        XCTAssertEqual(tester.phase, .done)
        XCTAssertNil(tester.lastResult?.pingMs)
        XCTAssertNil(tester.lastResult?.loadedPingMs)
    }

    func testFailedRunStopsTheLatencyProbes() async throws {
        let (restore, useServer) = speedSetUp()
        defer { restore() }
        ICMPBackend.probe = { _, _, _, _ in ("192.0.2.1", 5, true) }
        let dead = try LoopbackHTTPServer(mode: .status(200))
        let deadURL = dead.baseURL.absoluteString
        dead.stop()
        useServer(deadURL)

        let tester = MobileSpeedTester()
        tester.start(interface: "Wi-Fi")
        await waitFor(tester.$phase) { if case .failed = $0 { return true }; return false }
        XCTAssertNil(tester.loadedProbeTask, "a failed run must not leave ICMP probes running in the background")
    }

    func testServerThatSendsNothingIsAFailureNotAZeroMbpsResult() async throws {
        let (restore, useServer) = speedSetUp()
        defer { restore() }
        MobileSpeedTester.latencyProbesEnabled = false
        let server = try LoopbackHTTPServer(mode: .status(404))
        defer { server.stop() }
        useServer(server.baseURL.absoluteString)

        let tester = MobileSpeedTester()
        tester.start(interface: "Wi-Fi")
        await waitFor(tester.$phase) { if case .failed = $0 { return true }; return $0 == .done }
        guard case .failed(let why) = tester.phase else { return XCTFail("recorded \(String(describing: tester.lastResult)) instead of failing") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertNil(tester.lastResult, "a server that never delivers a byte records nothing")
        XCTAssertTrue(tester.history.isEmpty)
        XCTAssertNil(MobileSharedStore.readSpeed(), "and the widget keeps its previous value")
        XCTAssertNil(tester.loadedProbeTask)
    }

    func testRefusedUploadsDoNotCountAsThroughput() async throws {
        let server = try LoopbackHTTPServer(mode: .status(500))
        defer { server.stop() }
        let mbps = try await ThroughputRun.upload(baseURL: server.baseURL, seconds: 1.0, streams: 2) { _ in }
        XCTAssertNil(mbps, "a server that answers every POST with a 500 received nothing")
        XCTAssertTrue(server.requests.contains("POST /upload"))
    }

    func testDownsampleKeepsShortCurvesAndThinsLongOnes() {
        XCTAssertNil(MobileSpeedTester.downsample([]))
        XCTAssertEqual(MobileSpeedTester.downsample([1, 2, 3]), [1, 2, 3])
        let long = (0..<200).map(Double.init)
        let thin = MobileSpeedTester.downsample(long)
        XCTAssertEqual(thin?.count, 80)
        XCTAssertEqual(thin?.first, 0)
        XCTAssertLessThan(thin?.last ?? 1_000, 200)
        XCTAssertEqual(thin, thin?.sorted(), "still monotonic")
        XCTAssertEqual(MobileSpeedTester.downsample(long, to: 10)?.count, 10)
    }

    func testPublicRunnerErrorsHaveDistinctReadableMessages() {
        let errors: [OpenSpeedTestWidgetRunner.RunError] = [.loadFailed, .timedOut, .noResult, .cancelled]
        let messages = errors.map { MobileSpeedTester.describe($0) }
        XCTAssertEqual(Set(messages).count, 4)
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(MobileSpeedTester.describe(URLError(.notConnectedToInternet)),
                       (URLError(.notConnectedToInternet) as NSError).localizedDescription)
    }
}
