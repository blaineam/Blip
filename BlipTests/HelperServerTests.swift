import XCTest
import Network
@testable import Blip

// HelperServer is the helper's loopback TCP front: it publishes its port, polls the daemon,
// reads one length-prefixed JSON request per connection and answers through the router. The
// port file is pointed at scratch space so a helper the owner is running is never disturbed.

final class HelperServerTests: XCTestCase {
    private var dir: URL!
    private var portFile: URL!
    private var server: HelperServer!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blip-helperserver-\(UUID().uuidString)")
        portFile = dir.appendingPathComponent("nested/bliphelper_port")   // parent must be created by the server
        server = HelperServer(portFileURL: portFile)
        port = try XCTUnwrap(server.start(), "the helper's listener binds a loopback port")
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: wire helpers

    /// One request per connection, like the app's HelperClient: send a frame, read one frame back.
    private func exchange(_ frame: Data) async -> HelperResponse? {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }

        func receive(_ n: Int) async -> Data? {
            await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, error in
                    cont.resume(returning: error == nil && data?.count == n ? data : nil)
                }
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: frame, completion: .contentProcessed { _ in cont.resume() })
        }
        guard let header = await receive(4), let length = MessageFraming.decodeLength(from: header),
              let body = await receive(Int(length)) else { return nil }
        return try? JSONDecoder().decode(HelperResponse.self, from: body)
    }

    private func request(_ r: HelperRequest) async throws -> HelperResponse? {
        await exchange(try MessageFraming.encode(r))
    }

    // MARK: tests

    func testPublishesItsPortWhereTheAppLooksForIt() throws {
        XCTAssertEqual(try String(contentsOf: portFile, encoding: .utf8), String(port))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: portFile.path), "stopping withdraws the port")
    }

    func testRefusesBadTokensAndUnknownRequests() async throws {
        let denied = try await request(HelperRequest(type: "poll", token: "not-a-token"))
        XCTAssertEqual(denied?.type, "error")
        XCTAssertEqual(denied?.message, "Authentication failed")

        let unknown = try await request(HelperRequest(type: "frobnicate", token: TOTP.generate()))
        XCTAssertEqual(unknown?.message, "Unknown request type")
    }

    func testAnAuthenticatedKillOfAnInvalidPidIsRefusedByTheDaemon() async throws {
        let r = try await request(HelperRequest(type: "kill", token: TOTP.generate(), pid: 0, force: false))
        XCTAssertEqual(r?.type, "killResult")
        XCTAssertEqual(r?.success, false)
        XCTAssertEqual(r?.message, "Invalid PID")
        XCTAssertNotNil(r?.token, "responses carry a fresh token so the client can authenticate the helper")
    }

    func testKeepAwakeAndTracerouteRoutesReachTheDaemon() async throws {
        let idle = KeepAwakeExtrasRequest(lidClosed: false, jiggle: false)
        let keep = try await request(HelperRequest(type: "keepAwake", token: TOTP.generate(), keepAwake: idle))
        XCTAssertEqual(keep?.type, "keepAwake")
        XCTAssertEqual(keep?.keepAwake, KeepAwakeExtrasStatus())

        let trace = try await request(HelperRequest(type: "traceroute", token: TOTP.generate(), action: "stop"))
        XCTAssertEqual(trace?.type, "traceroute")
        XCTAssertEqual(trace?.running, false)
    }

    func testOversizedAndTruncatedFramesDropTheConnection() async {
        var tooBig = UInt32(HelperRequestRouter.maxRequestLength).bigEndian
        let huge = await exchange(Data(bytes: &tooBig, count: 4))
        XCTAssertNil(huge, "a frame claiming 64 KiB is refused before any body is read")

        var zero = UInt32(0).bigEndian
        let empty = await exchange(Data(bytes: &zero, count: 4))
        XCTAssertNil(empty)

        let garbage = await exchange((try? MessageFraming.encode(["not": "a request"])) ?? Data())
        XCTAssertEqual(garbage?.message, "Invalid request")
    }

    func testThePollLoopEventuallyServesASnapshot() async throws {
        let deadline = Date().addingTimeInterval(90)
        var snapshotResponse: HelperResponse?
        while Date() < deadline {
            let r = try await request(HelperRequest(type: "poll", token: TOTP.generate()))
            if r?.type == "snapshot" { snapshotResponse = r; break }
            XCTAssertEqual(r?.message, "No data available yet", "before the first poll lands")
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let snap = try XCTUnwrap(snapshotResponse?.data, "the daemon's first poll became servable")
        XCTAssertFalse(snap.topProcessesByMemory.isEmpty)
        XCTAssertNotNil(snap.helperVersion)
    }
}
