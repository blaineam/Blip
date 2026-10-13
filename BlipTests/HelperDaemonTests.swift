import XCTest
@testable import Blip

// Blip Helper has no test target, so HelperDaemon.swift is compiled into this bundle too (see
// project.yml). That runs the helper's real polling — SMC, IOKit, proc_*, diskutil, netstat,
// system_profiler — against the host and checks the snapshot it would hand the sandboxed app.

// BlipHelperApp.swift (not compiled here: it holds @main) supplies this in the helper itself.
extension HelperDaemon {
    func keepAwake(_ request: KeepAwakeExtrasRequest) -> KeepAwakeExtrasStatus { KeepAwakeExtrasStatus() }
}

final class HelperDaemonTests: XCTestCase {

    func testPollProducesAnInternallyConsistentSnapshot() throws {
        let daemon = HelperDaemon()
        let before = Date()
        let s = daemon.poll()

        XCTAssertGreaterThanOrEqual(s.timestamp, before.addingTimeInterval(-1))
        XCTAssertNotNil(s.helperVersion, "the helper stamps its bundle version so the app can spot a stale one")
        XCTAssertFalse((s.macModelName ?? "").isEmpty, "system_profiler names the Mac")

        // Fans: whatever the SMC reports is bounded and densely numbered.
        for (i, fan) in s.fans.enumerated() {
            XCTAssertEqual(fan.id, i)
            XCTAssertTrue((0...10_000).contains(fan.currentRPM), "rpm \(fan.currentRPM)")
        }
        if let cpu = s.cpuTemperature { XCTAssertTrue((-20...150).contains(cpu), "cpu \(cpu)") }
        if let gpu = s.gpuTemperature { XCTAssertTrue((-20...150).contains(gpu), "gpu \(gpu)") }
        XCTAssertTrue((0...100).contains(s.gpuUtilization))

        // Process lists: top fives, hottest first, never the helper itself.
        XCTAssertLessThanOrEqual(s.topProcessesByCPU.count, 5)
        XCTAssertLessThanOrEqual(s.topProcessesByMemory.count, 5)
        XCTAssertEqual(s.topProcessesByCPU.map(\.cpu), s.topProcessesByCPU.map(\.cpu).sorted(by: >))
        XCTAssertEqual(s.topProcessesByMemory.map(\.memory), s.topProcessesByMemory.map(\.memory).sorted(by: >))
        XCTAssertFalse(s.topProcessesByMemory.isEmpty)
        for p in s.topProcessesByCPU + s.topProcessesByMemory {
            XCTAssertNotEqual(p.pid, getpid())
            XCTAssertFalse(p.name.isEmpty)
        }

        for d in s.drives ?? [] {
            XCTAssertFalse(d.name.isEmpty)
            XCTAssertTrue(["Verified", "Failing", ""].contains(d.smartStatus), d.smartStatus)
        }
        if let h = s.batteryHealth { XCTAssertTrue((0...100).contains(h)) }
        if let c = s.batteryCycleCount { XCTAssertGreaterThanOrEqual(c, 0) }

        // It must survive the wire: the app receives exactly this over the framed channel.
        let frame = try MessageFraming.encode(HelperResponse(type: "snapshot", token: "123456", data: s, message: nil))
        XCTAssertEqual(MessageFraming.decodeLength(from: frame.prefix(4)), UInt32(frame.count - 4))
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded.data?.macModelName, s.macModelName)
        XCTAssertEqual(decoded.data?.topProcessesByMemory.map(\.pid), s.topProcessesByMemory.map(\.pid))
    }

    func testSecondPollReusesCachesAndKeepsCountersMonotonic() {
        let daemon = HelperDaemon()
        let a = daemon.poll()
        let b = daemon.poll()
        XCTAssertEqual(b.macModelName, a.macModelName, "model name is fetched once")
        XCTAssertEqual(b.smartStatus, a.smartStatus)
        XCTAssertEqual((b.drives ?? []).map(\.bsdName), (a.drives ?? []).map(\.bsdName), "drive health is cached between polls")
        XCTAssertGreaterThanOrEqual(b.diskTotalBytesRead, a.diskTotalBytesRead)
        XCTAssertGreaterThanOrEqual(b.diskTotalBytesWritten, a.diskTotalBytesWritten)
        XCTAssertEqual(b.networkTotalDownloaded, a.networkTotalDownloaded, "netstat totals refresh every few polls")
        XCTAssertGreaterThanOrEqual(b.timestamp, a.timestamp)
    }

    func testKillRefusesInvalidPids() {
        let daemon = HelperDaemon()
        XCTAssertEqual(daemon.killProcess(0, force: false).message, "Invalid PID")
        XCTAssertEqual(daemon.killProcess(1, force: true).ok, false)
    }

    func testTracerouteSessionLifecycle() {
        let daemon = HelperDaemon()
        XCTAssertEqual(daemon.tracerouteSnapshot().running, false)
        XCTAssertTrue(daemon.tracerouteSnapshot().hops.isEmpty)

        daemon.startTraceroute(host: "-bad")                 // looks like an option: never spawned
        XCTAssertFalse(daemon.tracerouteSnapshot().running)

        daemon.startTraceroute(host: "127.0.0.1")
        XCTAssertTrue(daemon.tracerouteSnapshot().running)
        daemon.startTraceroute(host: "127.0.0.1")            // same target, still running: left alone
        XCTAssertTrue(daemon.tracerouteSnapshot().running)
        daemon.startTraceroute(host: "localhost")            // new target replaces the session
        XCTAssertTrue(daemon.tracerouteSnapshot().running)

        daemon.stopTraceroute()
        let after = daemon.tracerouteSnapshot()
        XCTAssertFalse(after.running)
        XCTAssertTrue(after.hops.isEmpty)
        daemon.stopTraceroute()                              // idempotent
    }

    func testRouterDrivesTheRealDaemonThroughAnAuthenticatedKill() throws {
        let daemon = HelperDaemon()
        let body = try JSONEncoder().encode(HelperRequest(type: "kill", token: "000000", pid: 0, force: false))
        let ok = HelperRequestRouter.response(for: body, snapshot: nil, actions: daemon,
                                              validate: { $0 == "000000" }, generate: { "999999" })
        XCTAssertEqual(ok.type, "killResult")
        XCTAssertEqual(ok.success, false)
        XCTAssertEqual(ok.message, "Invalid PID")
        let denied = HelperRequestRouter.response(for: body, snapshot: nil, actions: daemon,
                                                  validate: { _ in false }, generate: { "x" })
        XCTAssertEqual(denied.type, "error")
    }
}
