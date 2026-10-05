import XCTest
import Combine
@testable import BlipMobile

// iOS feature coverage beyond the smoke gate: the disk speed test engine on a scratch
// folder, the self-hosted speed-test transfer engine against a loopback HTTP server,
// loopback ping/traceroute, the Shortcuts intents through their environment seam, the
// Bench widget's summary, and the share text. Nothing here touches the internet.

@MainActor
final class MobileFeatureTests: XCTestCase {

    /// Waits until `publisher` emits a value satisfying `condition` (event-driven, no sleeps).
    private func waitFor<P: Publisher>(_ publisher: P, timeout: TimeInterval = 60,
                                       _ condition: @escaping (P.Output) -> Bool) async where P.Failure == Never {
        let reached = expectation(description: "condition reached")
        reached.assertForOverFulfill = false
        let sub = publisher.sink { if condition($0) { reached.fulfill() } }
        await fulfillment(of: [reached], timeout: timeout)
        sub.cancel()
    }

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blip-mobile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: Disk speed test

    private static func isFinished(_ phase: MobileDiskBench.Phase) -> Bool {
        if case .failed = phase { return true }
        return phase == .done
    }

    func testDiskBenchOnAPickedFolderMeasuresAndCleansUp() async throws {
        let dir = try scratchDir()
        let bench = MobileDiskBench()
        bench.runExternal(at: dir)
        XCTAssertTrue(bench.isRunning)
        await waitFor(bench.$phase) { Self.isFinished($0) }

        XCTAssertEqual(bench.phase, .done, "failed with \(bench.phase)")
        let result = try XCTUnwrap(bench.result)
        XCTAssertGreaterThan(result.writeMBps, 0)
        XCTAssertGreaterThan(result.readMBps, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
                       "the hidden test file is removed")
    }

    func testDiskBenchCancelReturnsToIdleAndCleansUp() async throws {
        let dir = try scratchDir()
        let bench = MobileDiskBench()
        bench.runExternal(at: dir)
        bench.cancel()
        XCTAssertEqual(bench.phase, .idle)
        XCTAssertFalse(bench.isRunning)
        XCTAssertNil(bench.result)
        // The detached task notices the cancel between chunks and removes its file.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) {
            await Task.yield()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        XCTAssertNil(bench.result, "a cancelled run never publishes a result")
    }

    func testDiskBenchOnAMissingFolderFails() async throws {
        let bench = MobileDiskBench()
        bench.runExternal(at: try scratchDir().appendingPathComponent("gone"))
        await waitFor(bench.$phase) { Self.isFinished($0) }
        guard case .failed = bench.phase else { return XCTFail("expected failure, got \(bench.phase)") }
    }

    // MARK: Self-hosted speed test engine (loopback)

    func testThroughputRunDownloadAndUploadAgainstLoopback() async throws {
        let server = try LoopbackHTTPServer(mode: .speedTest(downloadBytes: 4_000_000))
        defer { server.stop() }

        let down = try await ThroughputRun.download(baseURL: server.baseURL, seconds: 1.2, streams: 2) { _ in }
        XCTAssertGreaterThan(down, 0)
        XCTAssertTrue(server.requests.contains("GET /downloading"))

        let up = try await ThroughputRun.upload(baseURL: server.baseURL, seconds: 1.2, streams: 2) { _ in }
        XCTAssertGreaterThan(try XCTUnwrap(up), 0)
        XCTAssertTrue(server.requests.contains("POST /upload"))
        XCTAssertGreaterThan(server.uploadedBytes, 0)
    }

    func testThroughputDownloadSurfacesConnectionErrors() async throws {
        let probe = try LoopbackHTTPServer(mode: .status(200))
        let deadURL = probe.baseURL
        probe.stop()
        do {
            _ = try await ThroughputRun.download(baseURL: deadURL, seconds: 1, streams: 1) { _ in }
            XCTFail("nothing is listening")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    func testLiveCounterIgnoresUnderHalfASecond() {
        let counter = LiveCounter(live: { _ in })
        counter.add(10_000_000)
        XCTAssertEqual(counter.finalMbps(), 0, "too short to be a measurement")
    }

    // MARK: Ping / traceroute (loopback)

    func testPingRunnerCollectsLoopbackSamples() async throws {
        let ping = PingRunner()
        ping.start(host: "127.0.0.1")
        XCTAssertTrue(ping.isRunning)
        await waitFor(ping.$samples, timeout: 15) { !$0.isEmpty }
        ping.stop()
        if ping.error != nil { throw XCTSkip("ICMP datagram sockets unavailable: \(ping.error!)") }
        let first = try XCTUnwrap(ping.samples.first)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertNotNil(first.rttMs, "loopback always answers")
        XCTAssertEqual(ping.stats.lossPercent, 0)
        XCTAssertFalse(ping.isRunning)
    }

    func testPingStatsComputeLoss() {
        let ping = PingRunner()
        ping.seedDemo([PingSample(sequence: 1, rttMs: 10), PingSample(sequence: 2, rttMs: nil),
                       PingSample(sequence: 3, rttMs: 20), PingSample(sequence: 4, rttMs: 30)])
        let s = ping.stats
        XCTAssertEqual(s.sent, 4)
        XCTAssertEqual(s.received, 3)
        XCTAssertEqual(s.lossPercent, 25)
        XCTAssertEqual(s.avgMs, 20)
        XCTAssertEqual(s.minMs, 10)
        XCTAssertEqual(s.maxMs, 30)
    }

    func testTraceRunnerReachesLoopbackInOneHop() async throws {
        let trace = TraceRunner()
        trace.start(host: "127.0.0.1", maxHops: 3)
        await waitFor(trace.$isRunning, timeout: 15) { !$0 }
        if let error = trace.error { throw XCTSkip("ICMP unavailable: \(error)") }
        let hop = try XCTUnwrap(trace.hops.first)
        XCTAssertEqual(hop.ttl, 1)
        XCTAssertEqual(hop.address, "127.0.0.1")
        XCTAssertTrue(hop.isDestination)
        XCTAssertEqual(trace.hops.count, 1, "stops at the destination")
    }

    func testRunnersIgnoreEmptyHosts() {
        let ping = PingRunner()
        ping.start(host: "")
        XCTAssertFalse(ping.isRunning)
        let trace = TraceRunner()
        trace.start(host: "")
        XCTAssertFalse(trace.isRunning)
    }

    // MARK: Shortcuts (through MobileIntentsEnvironment)

    private func benchResult(profile: BenchProfile = .full, composite: Double = 1_342.4,
                             date: Date = .now, throttle: Double? = 0.9) -> BenchResult {
        BenchResult(date: date, profile: profile,
                    singleCore: .init(name: "s", score: 711, results: []),
                    multiCore: .init(name: "m", score: 6_335, results: []),
                    memory: .init(name: "mem", score: 1_060, results: []),
                    gpu: .init(name: "g", score: 658, results: []), neural: nil,
                    throttleFactor: throttle, thermalSamples: [], composite: composite,
                    deviceModel: "iPhone18,1", osVersion: "iOS")
    }

    override func tearDown() async throws {
        MobileIntentsEnvironment.benchRunner = { _ in nil }
        MobileIntentsEnvironment.speedStarter = {}
        MobileIntentsEnvironment.snapshotProvider = { "" }
        MobileIntentsEnvironment.tabSwitcher = { _ in }
    }

    func testRunBenchmarkIntentRunsTheChosenProfileAndReturnsTheScore() async throws {
        var tabs: [String] = []
        var profiles: [BenchProfile] = []
        MobileIntentsEnvironment.tabSwitcher = { tabs.append($0) }
        MobileIntentsEnvironment.benchRunner = { profiles.append($0); return self.benchResult() }
        let intent = RunBenchmarkIntent()
        intent.profile = .full
        let result = try await intent.perform()
        XCTAssertEqual(result.value, 1_342.4)
        XCTAssertEqual(profiles, [.full])
        XCTAssertEqual(tabs, ["bench"], "the Bench tab is brought forward")
    }

    func testRunBenchmarkIntentFailsWhenCancelled() async {
        MobileIntentsEnvironment.benchRunner = { _ in nil }
        do {
            _ = try await RunBenchmarkIntent().perform()
            XCTFail("a cancelled benchmark must not return a score")
        } catch {
            guard case MobileIntentError.failed = error else { return XCTFail("\(error)") }
        }
    }

    func testRunSpeedTestIntentStartsTheSharedTester() async throws {
        var started = 0
        var tabs: [String] = []
        MobileIntentsEnvironment.speedStarter = { started += 1 }
        MobileIntentsEnvironment.tabSwitcher = { tabs.append($0) }
        _ = try await RunSpeedTestIntent().perform()
        XCTAssertEqual(started, 1)
        XCTAssertEqual(tabs, ["speed"])
    }

    func testDeviceSnapshotIntentReturnsMarkdownOrFails() async throws {
        MobileIntentsEnvironment.snapshotProvider = { "# Blip Snapshot\n## Device" }
        let md = try await GetDeviceSnapshotIntent().perform()
        XCTAssertEqual(md.value, "# Blip Snapshot\n## Device")

        MobileIntentsEnvironment.snapshotProvider = { "" }
        do {
            _ = try await GetDeviceSnapshotIntent().perform()
            XCTFail("an empty snapshot is an error, not an empty file")
        } catch {}
    }

    func testBenchProfileOptionMapping() {
        XCTAssertEqual(BenchProfileOption.quick.profile, .quick)
        XCTAssertEqual(BenchProfileOption.full.profile, .full)
    }

    // MARK: Widgets + share text

    func testBenchWidgetSummaryShowsLatestAndBestFullRun() {
        let history = [
            benchResult(profile: .full, composite: 1_200, date: Date(timeIntervalSince1970: 1)),
            benchResult(profile: .quick, composite: 1_900, date: Date(timeIntervalSince1970: 2)),
            benchResult(profile: .full, composite: 1_350, date: Date(timeIntervalSince1970: 3)),
            benchResult(profile: .quick, composite: 1_100, date: Date(timeIntervalSince1970: 4)),
        ]
        let s = MobileSharedStore.benchWidgetSummary(history)
        XCTAssertEqual(s.latest?.composite, 1_100)
        XCTAssertEqual(s.bestFull, 1_350, "quick runs never set the best")
        let empty = MobileSharedStore.benchWidgetSummary([])
        XCTAssertNil(empty.latest)
        XCTAssertNil(empty.bestFull)
        XCTAssertNil(MobileSharedStore.benchWidgetSummary([benchResult(profile: .quick)]).bestFull)
    }

    func testShareTexts() {
        let bench = ShareCard.benchText(benchResult())
        let lines = bench.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Blip Bench — iPhone 17 Pro")
        XCTAssertEqual(lines[1], "Composite 1342 (full run)")
        XCTAssertEqual(lines[2], "Single-core 711 · All cores 6335 · Memory 1060 · GPU 658")
        XCTAssertEqual(lines[3], "Sustained load loses 10%")

        var r = MobileSpeedResult(downMbps: 512.4, upMbps: 48.6, pingMs: 12.2, date: .now,
                                  interface: "Wi-Fi", source: "192.168.1.50")
        r.loadedPingMs = 40
        let speed = ShareCard.speedText(r).components(separatedBy: "\n")
        XCTAssertEqual(speed[0], "Network speed — 512 Mbps down · 49 Mbps up · 12 ms idle · 40 ms loaded")
        XCTAssertEqual(speed[1], ConnectionGrades.shareLines(
            ConnectionGrades.evaluate(down: 512.4, up: 48.6, unloadedMs: 12.2, loadedMs: 40)))
        XCTAssertEqual(speed[2], "via 192.168.1.50 on Wi-Fi")
    }

    func testSampleRingKeepsTheNewestCapacityValues() {
        var ring = SampleRing(capacity: 3)
        for v in 1...5 { ring.append(Double(v)) }
        XCTAssertEqual(ring.values, [3, 4, 5])
        XCTAssertEqual(SampleRing().capacity, 60)
    }

    func testDemoSeedDoesNothingUnlessRequested() {
        let prior = UserDefaults.standard.object(forKey: "blip.demoSeed")
        defer { UserDefaults.standard.set(prior, forKey: "blip.demoSeed") }
        UserDefaults.standard.removeObject(forKey: "blip.demoSeed")
        XCTAssertFalse(DemoSeed.active)

        let benchBefore = BenchHistory.load(defaults: MobileSharedStore.defaults).count
        let sourceBefore = UserDefaults.standard.string(forKey: "mobile.speed.source")
        DemoSeed.applyIfRequested()
        XCTAssertEqual(BenchHistory.load(defaults: MobileSharedStore.defaults).count, benchBefore,
                       "a real user's history is never seeded")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "mobile.speed.source"), sourceBefore)

        UserDefaults.standard.set(true, forKey: "blip.demoSeed")
        XCTAssertTrue(DemoSeed.active)
    }
}
