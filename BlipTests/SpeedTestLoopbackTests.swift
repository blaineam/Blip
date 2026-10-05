import XCTest
@testable import Blip

// The self-hosted OpenSpeedTest path measured for real — parallel URLSession transfers
// counted in delegate callbacks — against an in-process HTTP server on 127.0.0.1. Latency
// probes are pointed at loopback too, so nothing leaves the machine.

@MainActor
final class SpeedTestLoopbackTests: XCTestCase {

    private func tester() -> SpeedTester {
        let t = SpeedTester()
        t.phaseDuration = 1.5
        t.warmup = 0.3
        t.latencyHost = "127.0.0.1"
        return t
    }

    func testSelfHostedRunMeasuresBothDirectionsAndRecordsHistory() async throws {
        let server = try LoopbackHTTPServer(mode: .speedTest(downloadBytes: 4_000_000))
        defer { server.stop() }
        let t = tester()

        let result = try await t.runOnce(server: .openSpeedTest(baseURL: "127.0.0.1:\(server.port)/"), timeout: 60)

        XCTAssertGreaterThan(result.downMbps, 0)
        XCTAssertGreaterThan(try XCTUnwrap(result.upMbps), 0)
        XCTAssertEqual(t.phase, .done)
        XCTAssertEqual(t.history.count, 1)
        XCTAssertEqual(t.lastResult?.downMbps, result.downMbps)
        XCTAssertNotNil(result.downCurve, "the live curve is captured for the chart")
        XCTAssertLessThanOrEqual(result.downCurve?.count ?? 0, 80)
        if let ping = result.pingMs { XCTAssertGreaterThanOrEqual(ping, 0) }

        let requests = server.requests
        XCTAssertTrue(requests.contains("GET /downloading"), "normalized base URL hits the OST download path")
        XCTAssertTrue(requests.contains("POST /upload"))
        XCTAssertGreaterThan(server.uploadedBytes, 0)
        XCTAssertFalse(t.isRunning)
    }

    func testHTTPErrorBecomesAnActionableFailure() async throws {
        let server = try LoopbackHTTPServer(mode: .status(500))
        defer { server.stop() }
        let t = tester()
        t.phaseDuration = 1.0

        do {
            _ = try await t.runOnce(server: .openSpeedTest(baseURL: "http://127.0.0.1:\(server.port)"), timeout: 60)
            XCTFail("a 500 must not produce a result")
        } catch let failure as SpeedTestRunFailure {
            XCTAssertEqual(failure.message, "Server error (HTTP 500). Try again, or use an OpenSpeedTest server.")
        }
        XCTAssertTrue(t.history.isEmpty, "failed runs never enter history")
        if case .failed = t.phase {} else { XCTFail("phase should be .failed, got \(t.phase)") }
    }

    func testRateLimitMessage() async throws {
        let server = try LoopbackHTTPServer(mode: .status(429))
        defer { server.stop() }
        let t = tester()
        t.phaseDuration = 1.0
        do {
            _ = try await t.runOnce(server: .openSpeedTest(baseURL: "http://127.0.0.1:\(server.port)"), timeout: 60)
            XCTFail("expected failure")
        } catch let failure as SpeedTestRunFailure {
            XCTAssertTrue(failure.message.hasPrefix("Server busy (rate-limited)"), failure.message)
        }
        let downloads = server.requests.filter { $0 == "GET /downloading" }.count
        XCTAssertGreaterThan(downloads, 0)
        XCTAssertLessThanOrEqual(downloads, 6,
                                 "only the first parallel round is sent — a rate-limited server isn't hammered")
    }

    func testUnreachableServerFailsWithoutAResult() async throws {
        // Grab a free port, then close it so nothing listens there.
        let probe = try LoopbackHTTPServer(mode: .status(200))
        let port = probe.port
        probe.stop()
        let t = tester()
        t.phaseDuration = 1.0
        do {
            _ = try await t.runOnce(server: .openSpeedTest(baseURL: "http://127.0.0.1:\(port)"), timeout: 60)
            XCTFail("expected failure")
        } catch let failure as SpeedTestRunFailure {
            XCTAssertEqual(failure.message, "Network unavailable")
        }
    }
}
