import XCTest
import Combine
import SwiftUI
@testable import BlipMobile

// Ping + traceroute: the runners' state machines driven with scripted ICMP replies (no
// sockets, no network), and the Network Tools tab hosted in a window — demo-seeded, then
// driven through its real buttons.

@MainActor
final class MobileNetworkToolsTests: XCTestCase {

    private typealias Reply = ICMPBackend.Reply
    private let standardKeys = ["blip.demoSeed", "blip.demoNetworkMode", "mobile.ping.target", "mobile.trace.target"]
    private var defaults: DefaultsGuard!
    private var scratch: URL!
    private let oldResolve = ICMPBackend.resolve
    private let oldProbe = ICMPBackend.probe
    private let oldInterval = ICMPBackend.pingIntervalNanoseconds

    override func setUp() async throws {
        defaults = DefaultsGuard(standard: standardKeys)
        for k in standardKeys { UserDefaults.standard.removeObject(forKey: k) }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("blip-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        GeoIPDatabase.fileURLOverride = scratch.appendingPathComponent("dbip-city.mmdb")
        GeoIPDatabase.defaults = UserDefaults(suiteName: "blip.nettools.\(scratch.lastPathComponent)")!
        GeoIPDatabase.shared.remove()       // drops any reader a previous test left loaded
        ICMPBackend.resolve = { _ in sockaddr_in() }
        ICMPBackend.pingIntervalNanoseconds = 1_000_000
    }

    override func tearDown() async throws {
        ICMPBackend.resolve = oldResolve
        ICMPBackend.probe = oldProbe
        ICMPBackend.pingIntervalNanoseconds = oldInterval
        GeoIPDatabase.shared.remove()
        GeoIPDatabase.fileURLOverride = nil
        GeoIPDatabase.defaults = .standard
        GeoIPDatabase.shared.loadIfPresent()
        try? FileManager.default.removeItem(at: scratch)
        defaults.restore()
    }

    private func host<V: View>(_ view: V) -> Hosted {
        let h = Hosted(view)
        addTeardownBlock { @MainActor in h.close() }
        return h
    }

    private func waitFor<P: Publisher>(_ publisher: P, timeout: TimeInterval = 30,
                                       _ condition: @escaping (P.Output) -> Bool) async where P.Failure == Never {
        let reached = expectation(description: "condition reached")
        reached.assertForOverFulfill = false
        let sub = publisher.sink { if condition($0) { reached.fulfill() } }
        await fulfillment(of: [reached], timeout: timeout)
        sub.cancel()
    }

    /// Yields to the main actor (no wall-clock waiting) until `condition` holds.
    private func eventually(_ h: Hosted? = nil, limit: Int = 200_000, _ condition: () -> Bool) async {
        var n = 0
        while !condition() && n < limit {
            await Task.yield()
            h?.settle()
            n += 1
        }
    }

    private func installGeoFixture() throws {
        try MMDBFixtureBuilder.sample().write(to: GeoIPDatabase.fileURLOverride!)
        GeoIPDatabase.shared.loadIfPresent()
    }

    // MARK: Targets

    func testTargetsDefaultToCloudflareAndTrimWhitespace() {
        XCTAssertEqual(NetworkTargets.ping, "1.1.1.1")
        XCTAssertEqual(NetworkTargets.trace, "1.1.1.1")
        UserDefaults.standard.set("  192.0.2.7 \n", forKey: "mobile.ping.target")
        UserDefaults.standard.set("   ", forKey: "mobile.trace.target")
        XCTAssertEqual(NetworkTargets.ping, "192.0.2.7")
        XCTAssertEqual(NetworkTargets.trace, "1.1.1.1", "blank falls back to the default")
    }

    // MARK: PingRunner

    func testPingRunnerCollectsScriptedSamplesAndStops() async throws {
        let ttls = LockedBox<[Int32?]>([])
        ICMPBackend.probe = { _, ttl, seq, _ in
            ttls.mutate { $0.append(ttl) }
            return seq % 3 == 0 ? nil : ("192.0.2.1", Double(seq) * 2, true)
        }
        let ping = PingRunner()
        ping.start(host: "example.test")
        XCTAssertTrue(ping.isRunning)
        ping.start(host: "ignored.test")     // a second start while running is ignored
        await waitFor(ping.$samples) { $0.count >= 6 }
        ping.stop()
        XCTAssertFalse(ping.isRunning)
        XCTAssertNil(ping.error)
        XCTAssertTrue(ttls.value.allSatisfy { $0 == nil }, "ping probes carry no TTL limit")

        let samples = ping.samples
        XCTAssertEqual(samples.first?.sequence, 1)
        XCTAssertEqual(samples.first?.rttMs, 2)
        XCTAssertNil(samples.first { $0.sequence == 3 }?.rttMs, "a missing reply is a timeout, not an error")
        XCTAssertEqual(samples.map(\.sequence), Array(1...samples.count), "sequence numbers are contiguous")
        let stats = ping.stats
        XCTAssertEqual(stats.sent, samples.count)
        XCTAssertGreaterThan(stats.lossPercent, 0)
        XCTAssertEqual(stats.minMs, 2)
    }

    func testPingRunnerKeepsOnlyTheNewestFiftySamples() async {
        ICMPBackend.probe = { _, _, _, _ in ("192.0.2.1", 1, true) }
        let ping = PingRunner()
        ping.start(host: "example.test")
        await waitFor(ping.$samples) { ($0.last?.sequence ?? 0) >= 60 }
        ping.stop()
        XCTAssertLessThanOrEqual(ping.samples.count, 50)
        XCTAssertGreaterThan(ping.samples.first?.sequence ?? 0, 1, "the oldest samples were dropped")
    }

    func testPingRunnerReportsAnUnresolvableHost() async {
        ICMPBackend.resolve = { host in throw ICMPSocketError.resolveFailed(host) }
        let ping = PingRunner()
        ping.start(host: "nowhere.invalid")
        await waitFor(ping.$isRunning) { !$0 }
        XCTAssertEqual(ping.error, "Couldn't resolve nowhere.invalid")
        XCTAssertTrue(ping.samples.isEmpty)
        // Starting again clears the old error.
        ICMPBackend.resolve = { _ in sockaddr_in() }
        ICMPBackend.probe = { _, _, _, _ in ("192.0.2.1", 1, true) }
        ping.start(host: "example.test")
        XCTAssertNil(ping.error)
        ping.stop()
    }

    func testPingToggleStartsThenStops() {
        ICMPBackend.probe = { _, _, _, _ in ("192.0.2.1", 1, true) }
        let ping = PingRunner()
        ping.toggle(host: "example.test")
        XCTAssertTrue(ping.isRunning)
        ping.toggle(host: "example.test")
        XCTAssertFalse(ping.isRunning)
    }

    func testPingStatsOfNothingAreEmpty() {
        let s = PingRunner().stats
        XCTAssertEqual(s.sent, 0)
        XCTAssertEqual(s.lossPercent, 0)
        XCTAssertNil(s.avgMs)
        XCTAssertNil(s.minMs)
        XCTAssertNil(s.maxMs)
    }

    // MARK: TraceRunner

    func testTraceStopsAtTheDestinationAndMarksIt() async {
        ICMPBackend.probe = { _, ttl, _, _ in
            switch ttl {
            case 1: return ("192.168.1.1", 1.5, false)
            case 2: return nil                                // a silent hop
            default: return ("203.0.113.9", 20, true)
            }
        }
        let trace = TraceRunner()
        trace.start(host: "example.test")
        XCTAssertTrue(trace.isRunning)
        await waitFor(trace.$isRunning) { !$0 }
        XCTAssertNil(trace.error)
        XCTAssertEqual(trace.hops.map(\.ttl), [1, 2, 3])
        XCTAssertEqual(trace.hops[0].address, "192.168.1.1")
        XCTAssertNil(trace.hops[1].address)
        XCTAssertNil(trace.hops[1].rttMs)
        XCTAssertTrue(trace.hops[2].isDestination)
        XCTAssertFalse(trace.hops[0].isDestination)
    }

    func testTraceGivesUpAtMaxHops() async {
        ICMPBackend.probe = { _, ttl, _, _ in ("10.0.0.\(ttl ?? 0)", 1, false) }
        let trace = TraceRunner()
        trace.start(host: "example.test", maxHops: 4)
        await waitFor(trace.$isRunning) { !$0 }
        XCTAssertEqual(trace.hops.count, 4)
        XCTAssertFalse(trace.hops.contains { $0.isDestination })
    }

    func testTraceReportsAnUnresolvableHostAndCanBeToggled() async {
        ICMPBackend.resolve = { host in throw ICMPSocketError.resolveFailed(host) }
        let trace = TraceRunner()
        trace.toggle(host: "nowhere.invalid")
        await waitFor(trace.$isRunning) { !$0 }
        XCTAssertEqual(trace.error, "Couldn't resolve nowhere.invalid")
        XCTAssertTrue(trace.hops.isEmpty)
    }

    func testStoppingATraceMidwayLeavesItIdle() async {
        let probed = expectation(description: "first probe")
        probed.assertForOverFulfill = false
        ICMPBackend.probe = { _, ttl, _, _ in probed.fulfill(); return ("10.0.0.\(ttl ?? 0)", 1, false) }
        let trace = TraceRunner()
        trace.toggle(host: "example.test")
        await fulfillment(of: [probed], timeout: 30)
        trace.toggle(host: "example.test")          // second toggle stops
        XCTAssertFalse(trace.isRunning)
        XCTAssertNil(trace.error)
    }

    func testDemoSeedingAdoptsCannedData() {
        let ping = PingRunner(); ping.seedDemo(DemoSeed.pingSamples)
        XCTAssertEqual(ping.samples.count, 24)
        XCTAssertEqual(ping.stats.lossPercent, 4, "one canned timeout in 24")
        let trace = TraceRunner(); trace.seedDemo(DemoSeed.traceHops)
        XCTAssertEqual(trace.hops.count, 8)
        XCTAssertTrue(trace.hops.last?.isDestination ?? false)
    }

    // MARK: The tab

    func testPingModeShowsTheConfiguredTarget() {
        UserDefaults.standard.set("192.0.2.77", forKey: "mobile.ping.target")
        let h = host(NetworkToolsScreen())
        XCTAssertTrue(h.shows("net.mode"))
        XCTAssertTrue(h.shows("net.ping.start"))
        XCTAssertTrue(h.shows("Start Ping"))
        XCTAssertTrue(h.shows("192.0.2.77"))
        XCTAssertFalse(h.shows("net.ping.stat.sent"), "no samples yet")
    }

    func testDemoSeededPingShowsStatsAndTimeouts() {
        UserDefaults.standard.set(true, forKey: "blip.demoSeed")
        let h = host(NetworkToolsScreen())
        XCTAssertTrue(h.shows("net.ping.stat.sent"))
        XCTAssertTrue(h.shows("net.ping.stat.loss"))
        XCTAssertTrue(h.shows("4%"))
        XCTAssertTrue(h.shows("24"))
        XCTAssertTrue(h.shows("net.ping.stat.avg"))
        XCTAssertTrue(h.shows("net.ping.stat.minmax"))
        XCTAssertTrue(h.shows("net.ping.sample.24"))
        XCTAssertTrue(h.shows("net.ping.sample.13"), "the last twelve samples are listed")
        XCTAssertFalse(h.shows("net.ping.sample.12"))
    }

    func testDemoSeededTraceShowsEveryHopAndTheMap() {
        UserDefaults.standard.set(true, forKey: "blip.demoSeed")
        UserDefaults.standard.set("trace", forKey: "blip.demoNetworkMode")
        let h = host(NetworkToolsScreen())
        XCTAssertTrue(h.shows("Run Traceroute"))
        for ttl in 1...8 { XCTAssertTrue(h.shows("net.trace.hop.\(ttl)"), "hop \(ttl)") }
        XCTAssertTrue(h.shows("net.trace.map"))
        XCTAssertFalse(h.shows("net.trace.geoHint"), "demo mode never nags about the database")
    }

    func testPingButtonRunsTheScriptedProbesAndShowsSamples() async throws {
        let enough = expectation(description: "three probes")
        enough.assertForOverFulfill = false
        let count = LockedBox(0)
        ICMPBackend.probe = { _, _, seq, _ in
            count.mutate { $0 += 1 }
            if count.value >= 3 { enough.fulfill() }
            return ("192.0.2.1", 10 + Double(seq), true)
        }
        let h = host(NetworkToolsScreen())
        XCTAssertTrue(h.activate("net.ping.start"))
        await fulfillment(of: [enough], timeout: 30)
        await eventually(h) { h.shows("net.ping.sample.1") }
        XCTAssertTrue(h.shows("net.ping.sample.1"))
        XCTAssertTrue(h.shows("Stop"))
        XCTAssertTrue(h.shows("net.ping.stat.sent"))
        XCTAssertTrue(h.activate("net.ping.start"), "the same button stops the run")
        await eventually(h) { h.shows("Start Ping") }
        XCTAssertTrue(h.shows("Start Ping"))
    }

    func testPingErrorIsShownOnTheTab() async {
        ICMPBackend.resolve = { host in throw ICMPSocketError.resolveFailed(host) }
        let h = host(NetworkToolsScreen())
        XCTAssertTrue(h.activate("net.ping.start"))
        await eventually(h) { h.shows("net.error") }
        XCTAssertTrue(h.shows("net.error"))
        XCTAssertTrue(h.shows("Couldn't resolve 1.1.1.1"))
    }

    func testTraceWithoutADatabaseHintsAtSettingsThenLocatesHopsOnceInstalled() async throws {
        UserDefaults.standard.set("trace", forKey: "blip.demoNetworkMode")
        ICMPBackend.probe = { _, ttl, _, _ in
            ttl == 1 ? ("192.0.2.4", 3, false) : ("198.51.100.9", 9, true)
        }
        let h = host(NetworkToolsScreen())
        XCTAssertTrue(h.activate("net.trace.start"))
        await eventually(h) { h.shows("net.trace.hop.2") }
        XCTAssertTrue(h.shows("net.trace.hop.1"))
        XCTAssertTrue(h.shows("net.trace.hop.2"))
        XCTAssertTrue(h.shows("net.trace.geoHint"), "no database → a pointer to Settings")
        XCTAssertFalse(h.shows("net.trace.map"))
        XCTAssertFalse(h.shows("Testville"))
    }

    func testTraceWithADatabaseAnnotatesHopsAndDrawsTheMap() async throws {
        try installGeoFixture()
        XCTAssertTrue(GeoIPDatabase.shared.isReady)
        UserDefaults.standard.set("trace", forKey: "blip.demoNetworkMode")
        ICMPBackend.probe = { _, ttl, _, _ in
            ttl == 1 ? ("192.0.2.4", 3, false) : ("198.51.100.9", 9, true)
        }
        let h = host(NetworkToolsScreen())
        XCTAssertTrue(h.activate("net.trace.start"))
        await eventually(h) { h.shows("net.trace.hop.2") }
        XCTAssertTrue(h.shows("Testville"), "city, country from the offline database")
        XCTAssertTrue(h.shows("Berlin"))
        XCTAssertTrue(h.shows("net.trace.map"))
        XCTAssertFalse(h.shows("net.trace.geoHint"))
    }

    func testTraceHopMapPlotsOnlyLocatableHops() throws {
        try installGeoFixture()
        let located = [TraceHop(ttl: 1, address: "10.0.0.1", rttMs: 1),            // private: skipped
                       TraceHop(ttl: 2, address: nil, rttMs: nil),                 // silent
                       TraceHop(ttl: 3, address: "192.0.2.4", rttMs: 5),
                       { var h = TraceHop(ttl: 4, address: "203.0.113.70", rttMs: 9); h.isDestination = true; return h }()]
        let h = host(TraceHopMap(hops: located, geo: GeoIPDatabase.shared))
        XCTAssertTrue(h.shows("Testville, US"))
        XCTAssertFalse(h.shows("10.0.0.1"))
        // Nothing locatable → the view collapses.
        let empty = host(TraceHopMap(hops: [TraceHop(ttl: 1, address: "10.0.0.1", rttMs: 1)], geo: GeoIPDatabase.shared))
        XCTAssertFalse(empty.shows("Testville"))
    }
}
