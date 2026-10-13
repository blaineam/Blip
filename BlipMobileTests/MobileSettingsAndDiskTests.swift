import XCTest
import Combine
import SwiftUI
import Network
@testable import BlipMobile

// Settings (every GeoIP state the form can be in) and the Storage disk-speed section, hosted
// in a window; plus the disk engine's budget / failure paths on shrunken files.

@MainActor
final class MobileSettingsAndDiskTests: XCTestCase {

    private var scratch: URL!
    private var oldMaxBytes = MobileDiskBench.maxBytes
    private var oldBudget = MobileDiskBench.budget

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("blip-set-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        GeoIPDatabase.fileURLOverride = scratch.appendingPathComponent("dbip-city.mmdb")
        GeoIPDatabase.defaults = UserDefaults(suiteName: "blip.settings.\(scratch.lastPathComponent)")!
        GeoIPDatabase.candidatesOverride = nil
        GeoIPDatabase.shared.remove()       // drops any reader a previous test left loaded
        oldMaxBytes = MobileDiskBench.maxBytes
        oldBudget = MobileDiskBench.budget
        MobileDiskBench.maxBytes = 16 << 20       // two 8 MB chunks: fast, still real I/O
    }

    override func tearDown() async throws {
        MobileDiskBench.maxBytes = oldMaxBytes
        MobileDiskBench.budget = oldBudget
        GeoIPDatabase.shared.cancelDownload()
        GeoIPDatabase.shared.remove()
        GeoIPDatabase.fileURLOverride = nil
        GeoIPDatabase.defaults = .standard
        GeoIPDatabase.candidatesOverride = nil
        GeoIPDatabase.shared.loadIfPresent()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func host<V: View>(_ view: V) -> Hosted {
        let h = Hosted(view)
        addTeardownBlock { @MainActor in h.close() }
        return h
    }

    private func waitFor<P: Publisher>(_ publisher: P, timeout: TimeInterval = 120,
                                       _ condition: @escaping (P.Output) -> Bool) async where P.Failure == Never {
        let reached = expectation(description: "condition reached")
        reached.assertForOverFulfill = false
        let sub = publisher.sink { if condition($0) { reached.fulfill() } }
        await fulfillment(of: [reached], timeout: timeout)
        sub.cancel()
    }

    private func isFinished(_ phase: MobileDiskBench.Phase) -> Bool {
        if case .failed = phase { return true }
        return phase == .done
    }

    // MARK: Settings

    func testSettingsFormListsTheKnobsAndTheOfflineDatabaseDownload() {
        let h = host(NavigationStack { SettingsScreen() })
        XCTAssertTrue(h.shows("settings.form"))
        XCTAssertTrue(h.shows("settings.speedServer"))
        XCTAssertTrue(h.shows("settings.pingTarget"))
        XCTAssertTrue(h.shows("settings.traceTarget"))
        XCTAssertTrue(h.shows("Speed Test Server"))
        XCTAssertTrue(h.shows("settings.geoip.download"), "no database installed yet")
        XCTAssertFalse(h.shows("settings.geoip.remove"))
    }

    func testSettingsShowsAnInstalledDatabaseAndRemovesIt() throws {
        try MMDBFixtureBuilder.sample().write(to: GeoIPDatabase.fileURLOverride!)
        GeoIPDatabase.shared.loadIfPresent()
        let h = host(NavigationStack { SettingsScreen() })
        XCTAssertTrue(h.shows("settings.geoip.status"))
        XCTAssertTrue(h.shows("Installed"))
        XCTAssertTrue(h.shows("settings.geoip.updated"))
        XCTAssertTrue(h.shows(GeoIPDatabase.attribution))

        XCTAssertTrue(h.activate("settings.geoip.remove"))
        XCTAssertEqual(GeoIPDatabase.shared.status, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: GeoIPDatabase.fileURLOverride!.path))
        XCTAssertTrue(h.shows("settings.geoip.download"))
    }

    func testSettingsOffersARetryWhenTheDatabaseIsUnreadable() throws {
        try Data("not a database".utf8).write(to: GeoIPDatabase.fileURLOverride!)
        GeoIPDatabase.shared.loadIfPresent()
        guard case .failed = GeoIPDatabase.shared.status else { return XCTFail("\(GeoIPDatabase.shared.status)") }
        let h = host(NavigationStack { SettingsScreen() })
        XCTAssertTrue(h.shows("settings.geoip.status"))
        XCTAssertTrue(h.shows("Installed database is unreadable"))
        XCTAssertTrue(h.shows("settings.geoip.retry"))
    }

    func testSettingsShowsDownloadProgressAndCancels() async throws {
        let server = try SilentServer()      // accepts, never answers: the download stays in flight
        defer { server.stop() }
        GeoIPDatabase.candidatesOverride = [(tag: "2026-10", url: URL(string: "http://127.0.0.1:\(server.port)/db.mmdb.gz")!)]
        let h = host(NavigationStack { SettingsScreen() })     // appearing re-reads the (absent) file
        GeoIPDatabase.shared.download()
        guard case .downloading = GeoIPDatabase.shared.status else { return XCTFail("\(GeoIPDatabase.shared.status)") }
        h.settle()
        XCTAssertTrue(h.shows("settings.geoip.cancel"), "\(h.accessibilityStrings.sorted())")
        XCTAssertTrue(h.activate("settings.geoip.cancel"))
        await waitFor(GeoIPDatabase.shared.$status) { status in
            if case .downloading = status { return false }
            return true
        }
        let after = host(NavigationStack { SettingsScreen() })
        XCTAssertFalse(after.shows("settings.geoip.cancel"), "the progress row is gone once the download ends")
    }

    // MARK: Disk bench engine

    func testDiskBenchWithAnExhaustedBudgetFailsInsteadOfReportingNonsense() async throws {
        MobileDiskBench.budget = -1       // already over budget before the first chunk lands
        let bench = MobileDiskBench()
        bench.runExternal(at: scratch)
        await waitFor(bench.$phase) { self.isFinished($0) }
        guard case .failed(let why) = bench.phase else { return XCTFail("got \(bench.phase)") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertNil(bench.result)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [],
                       "the half-made test file is removed on failure too")
    }

    func testShrunkenDiskRunStillMeasuresBothDirections() async throws {
        let bench = MobileDiskBench()
        bench.runExternal(at: scratch)
        await waitFor(bench.$phase) { self.isFinished($0) }
        XCTAssertEqual(bench.phase, .done, "ended in \(bench.phase)")
        let r = try XCTUnwrap(bench.result)
        XCTAssertGreaterThan(r.writeMBps, 0)
        XCTAssertGreaterThan(r.readMBps, 0)
        XCTAssertEqual(r.volumeName.isEmpty, false)
    }

    // MARK: Disk section

    func testDiskSectionIdleOffersBothTests() {
        let h = host(List { MobileDiskBenchSection(bench: MobileDiskBench()) })
        XCTAssertTrue(h.shows("storage.disk.runInternal"))
        XCTAssertTrue(h.shows("storage.disk.pickFolder"))
        XCTAssertTrue(h.shows("Disk Speed"))
        XCTAssertFalse(h.shows("storage.disk.cancel"))
    }

    func testDiskSectionRunningShowsProgressAndCancelButton() {
        MobileDiskBench.maxBytes = 512 << 20
        let bench = MobileDiskBench()
        let h = host(List { MobileDiskBenchSection(bench: bench) })
        XCTAssertTrue(h.activate("storage.disk.runInternal"))
        XCTAssertTrue(bench.isRunning)
        XCTAssertTrue(h.shows("storage.disk.phase"))
        XCTAssertTrue(h.shows("Writing…"))
        XCTAssertTrue(h.shows("storage.disk.live"))
        XCTAssertTrue(h.activate("storage.disk.cancel"))
        XCTAssertEqual(bench.phase, .idle)
        XCTAssertTrue(h.shows("storage.disk.runInternal"))
    }

    func testDiskSectionShowsAResultAndAFailure() async throws {
        let bench = MobileDiskBench()
        bench.runExternal(at: scratch)
        await waitFor(bench.$phase) { self.isFinished($0) }
        XCTAssertEqual(bench.phase, .done)
        let done = host(List { MobileDiskBenchSection(bench: bench) })
        XCTAssertTrue(done.shows("storage.disk.result.volume"))
        XCTAssertTrue(done.shows("storage.disk.result.write"))
        XCTAssertTrue(done.shows("storage.disk.result.read"))
        XCTAssertTrue(done.shows("MB/s write"))

        bench.runExternal(at: scratch.appendingPathComponent("gone"))
        await waitFor(bench.$phase) { if case .failed = $0 { return true }; return false }
        let failed = host(List { MobileDiskBenchSection(bench: bench) })
        XCTAssertFalse(failed.shows("storage.disk.result.write"), "a new run clears the old result")
        XCTAssertTrue(failed.shows("exist"),
                      "the failure reason is shown: \(failed.accessibilityStrings.sorted())")
        XCTAssertTrue(failed.shows("storage.disk.runInternal"), "and the tests can be run again")
    }
}

/// Accepts TCP connections on loopback and never replies — a request to it stays in flight
/// until the client cancels.
final class SilentServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BlipMobileTests.SilentServer")
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    struct StartError: Error {}

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.connections.append(c)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let p = listener.port else { throw StartError() }
        port = p.rawValue
    }

    func stop() {
        listener.cancel()
        queue.async { self.connections.forEach { $0.cancel() }; self.connections = [] }
    }
}
