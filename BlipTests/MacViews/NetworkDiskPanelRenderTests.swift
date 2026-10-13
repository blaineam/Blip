import XCTest
import SwiftUI
@testable import Blip

/// Network and Disk detail panels with fixture stats, plus the speed-test sections driven
/// through every tester state (idle, running, done, failed) against loopback servers only.
@MainActor
final class NetworkDiskPanelRenderTests: XCTestCase {

    private var series: [Double] { (0..<60).map { Double(($0 * 7) % 23) * 1_000_000 } }

    private func net(_ edit: (inout NetworkStats) -> Void = { _ in }) -> NetworkStats {
        var n = Fixtures.snapshot().network
        n.isConnected = true; n.interfaceName = "en0"
        n.ipv4Address = "192.168.1.20"; n.ipv6Address = "fe80::1"; n.lanAddress = "192.168.1.20"
        n.wanAddress = "203.0.113.9"; n.routerIP = "192.168.1.1"; n.macAddress = "AA:BB:CC:DD:EE:FF"
        n.interfaces = [
            InterfaceInfo(id: "en0", name: "Wi-Fi", ipv4: "192.168.1.20", ipv6: "fe80::1", macAddress: "AA:BB:CC:DD:EE:FF", isActive: true),
            InterfaceInfo(id: "en5", name: "Ethernet", ipv4: "—", ipv6: "—", macAddress: "11:22:33:44:55:66", isActive: false),
        ]
        edit(&n)
        return n
    }

    private func panel(_ n: NetworkStats, tester: SpeedTester = SpeedTester(), prefs: [String: Any] = [:],
                       handlers: Bool = false) -> CGSize {
        if handlers {
            return ViewHost.smoke(NetworkDetailPanel(stats: n, downloadHistory: series, uploadHistory: series,
                speedTester: tester, traceStart: { _ in }, traceStop: {}, tracePoll: { ([], false) },
                onOpenTracerouteWindow: {}), prefs: prefs)
        }
        return ViewHost.smoke(NetworkDetailPanel(stats: n, downloadHistory: series, uploadHistory: series,
                                                 speedTester: tester), prefs: prefs)
    }

    func testNetworkPanelConnectionVariants() {
        let connected = panel(net())
        let offline = panel(NetworkStats())
        XCTAssertGreaterThan(connected.height, offline.height, "address rows only show while connected")
        _ = panel(net { $0.isVPNActive = true; $0.vpnAddress = "10.8.0.2"; $0.vpnInterface = "utun3" })
        _ = panel(net { $0.isExpensive = true; $0.isConstrained = true })
        _ = panel(net { $0.pingMs = nil; $0.routerPingMs = nil })
        _ = panel(net { $0.pingMs = 450; $0.routerPingMs = 90 })
        _ = panel(net { $0.interfaces = [] })
    }

    func testNetworkPanelExpandedSectionsAndTracerouteHandlers() {
        let prefs: [String: Any] = ["netSpeedExpanded": true, "traceExpanded": true, "tracerouteTarget": "example.com"]
        let expanded = panel(net(), prefs: prefs, handlers: true)
        let collapsed = panel(net(), handlers: true)
        XCTAssertGreaterThan(expanded.height, collapsed.height)
        _ = panel(net(), prefs: prefs.merging(["traceMapShown": true]) { $1 }, handlers: true)
        _ = panel(net(), prefs: ["traceExpanded": true], handlers: false)
    }

    func testSpeedSectionServerKindsAndAutoRun() {
        let t = SpeedTester()
        let base: [String: Any] = ["netSpeedExpanded": true]
        for extra: [String: Any] in [
            [:],
            ["speedTestServerKind": "selfhosted"],
            ["speedTestServerKind": "selfhosted", "speedTestOpenSpeedTestURL": "http://127.0.0.1:9/"],
            ["netSpeedAutoRun": true, "netSpeedInterval": 5],
        ] {
            ViewHost.smoke(SpeedTestSection(tester: t), prefs: base.merging(extra) { $1 })
        }
        ViewHost.smoke(SpeedTestSection(tester: t, isExpensiveNetwork: true), prefs: base)
    }

    func testSpeedSectionAfterSuccessfulAndFailedRuns() async throws {
        let server = try LoopbackHTTPServer(mode: .speedTest(downloadBytes: 4_000_000))
        defer { server.stop() }
        let t = SpeedTester()
        t.phaseDuration = 1.5; t.warmup = 0.3; t.latencyHost = "127.0.0.1"
        let target = SpeedTestServer.openSpeedTest(baseURL: "127.0.0.1:\(server.port)/")
        _ = try await t.runOnce(server: target, timeout: 60)
        XCTAssertEqual(t.phase, .done)
        let prefs: [String: Any] = ["netSpeedExpanded": true]
        let done = ViewHost.smoke(SpeedTestSection(tester: t), prefs: prefs)
        let collapsed = ViewHost.smoke(SpeedTestSection(tester: t))
        XCTAssertGreaterThan(done.height, collapsed.height)
        _ = panel(net(), tester: t, prefs: prefs)

        // Running: start() flips the phase synchronously; point it at loopback so nothing leaves the Mac.
        t.server = target
        t.start()
        XCTAssertTrue(t.isRunning)
        ViewHost.smoke(SpeedTestSection(tester: t), prefs: prefs)
        t.cancel()

        let bad = try LoopbackHTTPServer(mode: .status(500))
        defer { bad.stop() }
        let f = SpeedTester()
        f.phaseDuration = 1.0; f.warmup = 0.3; f.latencyHost = "127.0.0.1"
        _ = try? await f.runOnce(server: .openSpeedTest(baseURL: "http://127.0.0.1:\(bad.port)"), timeout: 60)
        if case .failed = f.phase {} else { XCTFail("expected failed, got \(f.phase)") }
        ViewHost.smoke(SpeedTestSection(tester: f), prefs: prefs)
    }

    func testTracerouteWindowAndMapRenderWithoutHops() {
        ViewHost.smoke(TracerouteWindowView(start: { _ in }, stop: {}, poll: { ([], false) }), width: 520)
        let hops = [HelperTraceHop(hop: 1, host: "192.168.1.1", sent: 3, recv: 3, lossPct: 0, lastMs: 1, avgMs: 1, bestMs: 1, worstMs: 2),
                    HelperTraceHop(hop: 2, host: "???", sent: 3, recv: 0, lossPct: 100, lastMs: nil, avgMs: nil, bestMs: nil, worstMs: nil)]
        ViewHost.smoke(TracerouteMapView(hops: hops), width: 320)
        ViewHost.smoke(BlipToggle(title: "Option", isOn: .constant(true)))
        ViewHost.smoke(BlipToggle(title: "Option", isOn: .constant(false), onChange: { _ in }))
    }

    func testGeoIPLookupClassifiesPublicAddresses() {
        for ip in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "100.63.0.1", "100.128.0.1", "11.0.0.1"] {
            XCTAssertTrue(GeoIPLookup.isPublicIPv4(ip), ip)
        }
        for ip in ["10.1.2.3", "127.0.0.1", "0.0.0.0", "172.16.0.1", "172.31.255.255", "192.168.0.1",
                   "169.254.1.1", "100.64.0.1", "100.127.0.1", "224.0.0.1", "255.255.255.255",
                   "1.2.3", "a.b.c.d", "", "1.2.3.4.5"] {
            XCTAssertFalse(GeoIPLookup.isPublicIPv4(ip), ip)
        }
    }

    // MARK: Disk

    private func disk(_ edit: (inout DiskStats) -> Void = { _ in }) -> DiskStats {
        var d = Fixtures.snapshot().disk
        edit(&d)
        return d
    }

    private func diskPanel(_ d: DiskStats, hasIO: Bool = true, tester: DiskSpeedTester = DiskSpeedTester(),
                           prefs: [String: Any] = [:]) -> CGSize {
        ViewHost.smoke(DiskDetailPanel(stats: d, readHistory: series, writeHistory: series, hasIOData: hasIO,
                                       speedTester: tester), prefs: prefs)
    }

    func testDiskPanelVolumesDrivesAndIOAvailability() {
        let full = diskPanel(disk())
        let noIO = diskPanel(disk(), hasIO: false)
        XCTAssertNotEqual(full.height, noIO.height, "I/O charts only render when the source provides them")
        _ = diskPanel(disk { $0.volumes = [] ; $0.drives = []; $0.smartStatus = "" })
        _ = diskPanel(disk { $0.volumes = [VolumeInfo(name: "Full", mountPoint: "/Volumes/Full", totalBytes: 100, freeBytes: 2)] })
        _ = diskPanel(disk { $0.smartStatus = "Failing" })
        let bad = Fixtures.drive(name: "BAD", percentageUsed: 95, tempC: 78, healthy: false)
        let unknown = Fixtures.drive(name: "NEW", percentageUsed: nil, tempC: nil, healthy: true)
        _ = diskPanel(disk { $0.drives = [bad, unknown] })
    }

    func testDiskSpeedTestSectionStates() {
        let t = DiskSpeedTester()
        let prefs: [String: Any] = ["diskSpeedExpanded": true]
        let idle = diskPanel(disk(), tester: t, prefs: prefs)
        t.record(DiskSpeedResult(writeMBps: 2000, readMBps: 3000, randomReadIOPS: 150_000, timestamp: Date()))
        t.record(DiskSpeedResult(writeMBps: 1800, readMBps: 2900, randomReadIOPS: nil, timestamp: Date()))
        let withResult = diskPanel(disk(), tester: t, prefs: prefs)
        XCTAssertGreaterThan(withResult.height, idle.height, "results and history add rows")
        _ = diskPanel(disk(), tester: t, prefs: prefs.merging(["diskSpeedAutoRun": true, "diskSpeedInterval": 15]) { $1 })
        t.size = .small
        t.start()
        XCTAssertTrue(t.isRunning)
        _ = diskPanel(disk(), tester: t, prefs: prefs)
        t.cancel()
    }
}
