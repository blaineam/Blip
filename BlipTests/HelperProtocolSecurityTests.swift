import XCTest
import Network
@testable import Blip

// The App Store build's privileged channel: Blip ⇄ Blip Helper over loopback TCP,
// length-prefixed JSON, TOTP on every request and response. These tests pin the security
// rules (authenticate before dispatch, refuse bad frames, client verifies the server too)
// and run the real HelperClient against an in-process server built on the same router
// the helper uses.

/// Records what the router asked the daemon to do.
final class FakeHelperDaemon: HelperDaemonActions, @unchecked Sendable {
    private let lock = NSLock()
    private var _kills: [(pid: pid_t, force: Bool)] = []
    private var _traceStarts: [String] = []
    private var _traceStops = 0
    private var _keepAwake: [KeepAwakeExtrasRequest] = []
    var killResult: (ok: Bool, message: String) = (true, "Terminated")
    var traceHops: [HelperTraceHop] = []
    var keepAwakeReply = KeepAwakeExtrasStatus(lidClosed: true, jiggle: true)

    var kills: [(pid: pid_t, force: Bool)] { lock.withLock { _kills } }
    var traceStarts: [String] { lock.withLock { _traceStarts } }
    var traceStops: Int { lock.withLock { _traceStops } }
    var keepAwakeRequests: [KeepAwakeExtrasRequest] { lock.withLock { _keepAwake } }
    var touched: Bool { !kills.isEmpty || !traceStarts.isEmpty || traceStops > 0 || !keepAwakeRequests.isEmpty }

    func killProcess(_ pid: pid_t, force: Bool) -> (ok: Bool, message: String) {
        lock.withLock { _kills.append((pid, force)) }
        return killResult
    }
    func startTraceroute(host: String) { lock.withLock { _traceStarts.append(host) } }
    func stopTraceroute() { lock.withLock { _traceStops += 1 } }
    func tracerouteSnapshot() -> (hops: [HelperTraceHop], running: Bool) {
        lock.withLock { (traceHops, !_traceStarts.isEmpty && _traceStops == 0) }
    }
    func keepAwake(_ request: KeepAwakeExtrasRequest) -> KeepAwakeExtrasStatus {
        lock.withLock { _keepAwake.append(request) }
        return keepAwakeReply
    }
}

final class HelperProtocolSecurityTests: XCTestCase {

    private func body(_ request: HelperRequest) throws -> Data {
        try JSONEncoder().encode(request)
    }

    private func route(_ request: HelperRequest, daemon: FakeHelperDaemon,
                       snapshot: HelperSnapshot? = nil) throws -> HelperResponse {
        HelperRequestRouter.response(for: try body(request), snapshot: snapshot, actions: daemon)
    }

    // MARK: Framing

    func testDecodeLengthRejectsShortHeaders() {
        XCTAssertNil(MessageFraming.decodeLength(from: Data()))
        XCTAssertNil(MessageFraming.decodeLength(from: Data([0x00, 0x01, 0x02])))
        XCTAssertEqual(MessageFraming.decodeLength(from: Data([0x00, 0x00, 0x01, 0x00])), 256)
        XCTAssertEqual(MessageFraming.decodeLength(from: Data([0xFF, 0xFF, 0xFF, 0xFF])), UInt32.max)
    }

    func testEncodedFrameHeaderIsBigEndianPayloadLength() throws {
        let frame = try MessageFraming.encode(HelperRequest(type: "poll", token: "123456"))
        let length = try XCTUnwrap(MessageFraming.decodeLength(from: frame.prefix(4)))
        XCTAssertEqual(Int(length), frame.count - 4)
        XCTAssertEqual(frame[0], 0, "a small request's top length byte is zero (big-endian)")
    }

    func testServerFrameLimitRejectsEmptyAndOversizedBodies() {
        XCTAssertFalse(HelperRequestRouter.isAcceptableRequestLength(0))
        XCTAssertTrue(HelperRequestRouter.isAcceptableRequestLength(1))
        XCTAssertTrue(HelperRequestRouter.isAcceptableRequestLength(65_535))
        XCTAssertFalse(HelperRequestRouter.isAcceptableRequestLength(65_536))
        XCTAssertFalse(HelperRequestRouter.isAcceptableRequestLength(UInt32.max))
    }

    func testEveryRequestTypeRoundTripsThroughJSON() throws {
        var kill = HelperRequest(type: "kill", token: "111111")
        kill.pid = 4242
        kill.force = true
        var trace = HelperRequest(type: "traceroute", token: "222222")
        trace.action = "start"
        trace.host = "1.1.1.1"
        var awake = HelperRequest(type: "keepAwake", token: "333333")
        awake.keepAwake = KeepAwakeExtrasRequest(lidClosed: true, jiggle: false, requestJigglePermission: true)

        for request in [HelperRequest(type: "poll", token: "000000"), kill, trace, awake] {
            let decoded = try JSONDecoder().decode(HelperRequest.self, from: try body(request))
            XCTAssertEqual(decoded.type, request.type)
            XCTAssertEqual(decoded.token, request.token)
            XCTAssertEqual(decoded.pid, request.pid)
            XCTAssertEqual(decoded.force, request.force)
            XCTAssertEqual(decoded.action, request.action)
            XCTAssertEqual(decoded.host, request.host)
            XCTAssertEqual(decoded.keepAwake, request.keepAwake)
        }
    }

    func testOldClientJSONWithoutOptionalFieldsStillDecodes() throws {
        let legacy = Data(#"{"type":"poll","token":"123456"}"#.utf8)
        let request = try JSONDecoder().decode(HelperRequest.self, from: legacy)
        XCTAssertNil(request.pid)
        XCTAssertNil(request.keepAwake)
    }

    // MARK: TOTP

    func testTOTPAcceptsOnlyTheAdjacentWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(TOTP.validate(TOTP.generate(at: now), at: now))
        XCTAssertTrue(TOTP.validate(TOTP.generate(at: now.addingTimeInterval(-30)), at: now), "one step of drift is allowed")
        XCTAssertTrue(TOTP.validate(TOTP.generate(at: now.addingTimeInterval(30)), at: now))
        XCTAssertFalse(TOTP.validate(TOTP.generate(at: now.addingTimeInterval(-60)), at: now), "two steps old is a replay")
        XCTAssertFalse(TOTP.validate(TOTP.generate(at: now.addingTimeInterval(90)), at: now))
    }

    func testTOTPRejectsMalformedTokens() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let good = TOTP.generate(at: now)
        XCTAssertEqual(good.count, 6)
        XCTAssertTrue(good.allSatisfy(\.isNumber))
        XCTAssertFalse(TOTP.validate("", at: now))
        XCTAssertFalse(TOTP.validate("abcdef", at: now))
        XCTAssertFalse(TOTP.validate(good + "0", at: now))
        XCTAssertFalse(TOTP.validate(String(good.dropFirst()), at: now))
    }

    // MARK: Router

    func testBadTokenIsRejectedBeforeReachingTheDaemon() throws {
        let daemon = FakeHelperDaemon()
        for type in ["poll", "kill", "traceroute", "keepAwake"] {
            var request = HelperRequest(type: type, token: "not-a-totp")
            request.pid = 999
            request.action = "start"
            request.host = "1.1.1.1"
            request.keepAwake = KeepAwakeExtrasRequest(lidClosed: true, jiggle: true)
            let response = try route(request, daemon: daemon, snapshot: Self.snapshot())
            XCTAssertEqual(response.type, "error")
            XCTAssertEqual(response.message, "Authentication failed")
            XCTAssertNil(response.token, "errors carry no token")
            XCTAssertNil(response.data, "no privileged data leaks on auth failure")
        }
        XCTAssertFalse(daemon.touched, "an unauthenticated request must never reach the daemon")
    }

    func testGarbageBodyIsAnInvalidRequest() {
        let daemon = FakeHelperDaemon()
        let response = HelperRequestRouter.response(for: Data("{not json".utf8), snapshot: nil, actions: daemon)
        XCTAssertEqual(response.type, "error")
        XCTAssertEqual(response.message, "Invalid request")
        XCTAssertFalse(daemon.touched)
    }

    func testKillWithoutPIDIsRefused() throws {
        let daemon = FakeHelperDaemon()
        let response = try route(HelperRequest(type: "kill", token: TOTP.generate()), daemon: daemon)
        XCTAssertEqual(response.message, "Missing PID")
        XCTAssertTrue(daemon.kills.isEmpty)
    }

    func testKillDispatchesPIDAndForceAndReportsResult() throws {
        let daemon = FakeHelperDaemon()
        daemon.killResult = (false, "Permission denied (system process)")
        var request = HelperRequest(type: "kill", token: TOTP.generate())
        request.pid = 4321
        request.force = true
        let response = try route(request, daemon: daemon)
        XCTAssertEqual(response.type, "killResult")
        XCTAssertEqual(daemon.kills.first?.pid, 4321)
        XCTAssertEqual(daemon.kills.first?.force, true)
        XCTAssertEqual(response.success, false)
        XCTAssertEqual(response.message, "Permission denied (system process)")
        XCTAssertTrue(TOTP.validate(try XCTUnwrap(response.token)), "responses are signed so the client can verify them")
    }

    func testKillDefaultsToSIGTERM() throws {
        let daemon = FakeHelperDaemon()
        var request = HelperRequest(type: "kill", token: TOTP.generate())
        request.pid = 77
        _ = try route(request, daemon: daemon)
        XCTAssertEqual(daemon.kills.first?.force, false)
    }

    func testUnknownTypeIsAnError() throws {
        let daemon = FakeHelperDaemon()
        let response = try route(HelperRequest(type: "shell", token: TOTP.generate()), daemon: daemon)
        XCTAssertEqual(response.type, "error")
        XCTAssertEqual(response.message, "Unknown request type")
        XCTAssertFalse(daemon.touched)
    }

    func testPollBeforeFirstSampleIsAnErrorThenReturnsSnapshot() throws {
        let daemon = FakeHelperDaemon()
        let early = try route(HelperRequest(type: "poll", token: TOTP.generate()), daemon: daemon)
        XCTAssertEqual(early.message, "No data available yet")

        let ready = try route(HelperRequest(type: "poll", token: TOTP.generate()), daemon: daemon, snapshot: Self.snapshot())
        XCTAssertEqual(ready.type, "snapshot")
        XCTAssertEqual(ready.data?.helperVersion, "2.0.6")
    }

    func testTracerouteStartWithoutHostDoesNotStartASession() throws {
        let daemon = FakeHelperDaemon()
        var request = HelperRequest(type: "traceroute", token: TOTP.generate())
        request.action = "start"
        let response = try route(request, daemon: daemon)
        XCTAssertTrue(daemon.traceStarts.isEmpty)
        XCTAssertEqual(response.type, "traceroute")
        XCTAssertEqual(response.running, false)
    }

    func testTracerouteStartStopAndPoll() throws {
        let daemon = FakeHelperDaemon()
        daemon.traceHops = [Fixtures.hop(1, host: "192.0.2.1", sent: 4, recv: 4, avg: 1.5)]
        var start = HelperRequest(type: "traceroute", token: TOTP.generate())
        start.action = "start"
        start.host = "198.51.100.7"
        let started = try route(start, daemon: daemon)
        XCTAssertEqual(daemon.traceStarts, ["198.51.100.7"])
        XCTAssertEqual(started.running, true)
        XCTAssertEqual(started.hops?.first?.host, "192.0.2.1")

        var poll = HelperRequest(type: "traceroute", token: TOTP.generate())
        poll.action = "poll"
        _ = try route(poll, daemon: daemon)
        XCTAssertEqual(daemon.traceStarts.count, 1, "poll never restarts the session")

        var stop = HelperRequest(type: "traceroute", token: TOTP.generate())
        stop.action = "stop"
        let stopped = try route(stop, daemon: daemon)
        XCTAssertEqual(daemon.traceStops, 1)
        XCTAssertEqual(stopped.running, false)
    }

    func testKeepAwakeForwardsRequestAndDefaultsToOff() throws {
        let daemon = FakeHelperDaemon()
        var on = HelperRequest(type: "keepAwake", token: TOTP.generate())
        on.keepAwake = KeepAwakeExtrasRequest(lidClosed: true, jiggle: false)
        let reply = try route(on, daemon: daemon)
        XCTAssertEqual(reply.keepAwake, daemon.keepAwakeReply)

        // An old client that omits the payload is treated as "everything off".
        _ = try route(HelperRequest(type: "keepAwake", token: TOTP.generate()), daemon: daemon)
        XCTAssertEqual(daemon.keepAwakeRequests,
                       [KeepAwakeExtrasRequest(lidClosed: true, jiggle: false),
                        KeepAwakeExtrasRequest(lidClosed: false, jiggle: false)])
    }

    // MARK: Process signalling

    func testSignallerRefusesKernelLaunchdAndProcessGroups() {
        var sent: [(pid_t, Int32)] = []
        for pid: pid_t in [0, 1, -1, -500] {
            let r = ProcessSignaller.terminate(pid, force: true, send: { sent.append(($0, $1)); return 0 })
            XCTAssertFalse(r.ok)
            XCTAssertEqual(r.message, "Invalid PID")
        }
        XCTAssertTrue(sent.isEmpty, "kill(0/-1/…) would signal whole process groups — never sent")
    }

    func testSignallerPicksSignalAndMapsErrnos() {
        var signals: [Int32] = []
        let term = ProcessSignaller.terminate(500, force: false, send: { signals.append($1); return 0 })
        let hard = ProcessSignaller.terminate(500, force: true, send: { signals.append($1); return 0 })
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
        XCTAssertEqual(term.message, "Terminated")
        XCTAssertEqual(hard.message, "Force killed")

        let eperm = ProcessSignaller.terminate(500, force: false, send: { _, _ in -1 }, lastErrno: { EPERM })
        XCTAssertEqual(eperm.ok, false)
        XCTAssertEqual(eperm.message, "Permission denied (system process)")
        let esrch = ProcessSignaller.terminate(500, force: false, send: { _, _ in -1 }, lastErrno: { ESRCH })
        XCTAssertEqual(esrch.message, "Process no longer running")
        XCTAssertEqual(ProcessSignaller.message(forErrno: EINVAL), "Failed (errno \(EINVAL))")
    }

    // MARK: Loopback round trip (real HelperClient ⇄ router over 127.0.0.1)

    @MainActor
    func testClientPollsSnapshotOverLoopback() async throws {
        let daemon = FakeHelperDaemon()
        let server = try TestHelperServer(daemon: daemon, snapshot: Self.snapshot())
        defer { server.stop() }
        let client = HelperClient(portFileURL: server.portFile)

        await client.poll()
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(client.latestSnapshot?.helperVersion, "2.0.6")
        XCTAssertEqual(client.latestSnapshot?.fans.first?.currentRPM, 2_000)
    }

    @MainActor
    func testClientKillTracerouteAndKeepAwakeOverLoopback() async throws {
        let daemon = FakeHelperDaemon()
        daemon.traceHops = [Fixtures.hop(1, host: "192.0.2.1", sent: 2, recv: 1, avg: 3)]
        let server = try TestHelperServer(daemon: daemon, snapshot: Self.snapshot())
        defer { server.stop() }
        let client = HelperClient(portFileURL: server.portFile)

        let kill = await client.killProcess(pid: 31337, force: false)
        XCTAssertTrue(kill.ok)
        XCTAssertEqual(kill.message, "Terminated")
        XCTAssertEqual(daemon.kills.first?.pid, 31337)

        await client.startTraceroute(host: "192.0.2.55")
        let trace = await client.tracerouteHops()
        XCTAssertEqual(daemon.traceStarts, ["192.0.2.55"])
        XCTAssertTrue(trace.running)
        XCTAssertEqual(trace.hops.first?.recv, 1)
        await client.stopTraceroute()
        XCTAssertEqual(daemon.traceStops, 1)

        let status = await client.keepAwake(KeepAwakeExtrasRequest(lidClosed: true, jiggle: true))
        XCTAssertEqual(status, daemon.keepAwakeReply)
    }

    @MainActor
    func testClientRejectsResponsesWithoutAValidServerToken() async throws {
        let daemon = FakeHelperDaemon()
        let server = try TestHelperServer(daemon: daemon, snapshot: Self.snapshot(), signResponses: { "000000" })
        defer { server.stop() }
        let client = HelperClient(portFileURL: server.portFile)

        let kill = await client.killProcess(pid: 31337, force: false)
        XCTAssertFalse(kill.ok)
        XCTAssertEqual(kill.message, "Helper unavailable", "an unsigned reply is treated as no helper at all")
        let status = await client.keepAwake(KeepAwakeExtrasRequest(lidClosed: false, jiggle: false))
        XCTAssertNil(status)
    }

    @MainActor
    func testClientRefusesOversizedResponseFrames() async throws {
        let server = try TestHelperServer(rawReply: { _ in
            var header = UInt32(2 << 20).bigEndian   // 2 MiB — over the client's 1 MiB cap
            return Data(bytes: &header, count: 4)
        })
        defer { server.stop() }
        let client = HelperClient(portFileURL: server.portFile)
        let kill = await client.killProcess(pid: 4000, force: true)
        XCTAssertEqual(kill.message, "Helper unavailable")
    }

    @MainActor
    func testClientWithoutPortFileStaysDisconnected() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("blip-no-port-\(UUID().uuidString)")
        let client = HelperClient(portFileURL: missing)
        for _ in 0..<3 { await client.poll() }
        XCTAssertFalse(client.isConnected)
        XCTAssertNil(client.latestSnapshot)
        let kill = await client.killProcess(pid: 4000, force: false)
        XCTAssertEqual(kill.message, "Helper unavailable")
    }

    // MARK: Fixtures

    static func snapshot() -> HelperSnapshot {
        HelperSnapshot(
            fans: [HelperFan(id: 0, name: "Left", currentRPM: 2_000, minRPM: 1_200, maxRPM: 5_900)],
            cpuTemperature: 51, gpuTemperature: 44, gpuUtilization: 12,
            diskReadBytesPerSec: 1, diskWriteBytesPerSec: 2, diskTotalBytesRead: 3, diskTotalBytesWritten: 4,
            smartStatus: "Verified", drives: nil, networkTotalDownloaded: nil, networkTotalUploaded: nil,
            batteryHealth: nil, batteryCycleCount: nil, batteryCondition: nil, batteryTemperature: nil,
            topProcessesByCPU: [], topProcessesByMemory: [], macModelName: "Test Mac",
            helperVersion: "2.0.6", timestamp: Date(timeIntervalSince1970: 1_800_000_000))
    }
}

/// A loopback stand-in for Blip Helper's HelperServer: same framing, same router, a fake
/// daemon, and the port published through a temp port file the client is pointed at.
final class TestHelperServer: @unchecked Sendable {
    let portFile: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BlipTests.TestHelperServer")

    convenience init(daemon: FakeHelperDaemon, snapshot: HelperSnapshot?,
                     signResponses: @escaping @Sendable () -> String = { TOTP.generate() }) throws {
        try self.init(rawReply: { body in
            let response = HelperRequestRouter.response(for: body, snapshot: snapshot, actions: daemon,
                                                         generate: signResponses)
            return (try? MessageFraming.encode(response)) ?? Data()
        })
    }

    /// `rawReply` maps a request body to the exact bytes written back.
    init(rawReply: @escaping @Sendable (Data) -> Data) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        portFile = FileManager.default.temporaryDirectory.appendingPathComponent("blip-test-port-\(UUID().uuidString)")

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
                guard let header, let length = MessageFraming.decodeLength(from: header),
                      HelperRequestRouter.isAcceptableRequestLength(length) else { connection.cancel(); return }
                connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                    guard let body else { connection.cancel(); return }
                    connection.send(content: rawReply(body), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw XCTSkip("Couldn't open a loopback listener")
        }
        try String(port).write(to: portFile, atomically: true, encoding: .utf8)
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(at: portFile)
    }
}
