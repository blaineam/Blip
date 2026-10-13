import XCTest
import WebKit
@testable import BlipMobile

// The iOS port of the OpenSpeedTest widget runner. The page itself needs the internet, so these
// tests feed the runner the same messages the injected script posts (and the WebKit navigation
// failures) and check how it resolves the run. Nothing is awaited by sleeping: the run's
// continuation is resolved by the message under test.

private final class FakeScriptMessage: WKScriptMessage {
    private let payload: Any
    init(_ body: Any) { payload = body; super.init() }
    override var body: Any { payload }
}

@MainActor
final class OSTWidgetRunnerTests: XCTestCase {
    typealias Live = (isUpload: Bool, mbps: Double?)

    /// Starts a run and returns once the runner is parked on its continuation.
    private func startRun(_ runner: OpenSpeedTestWidgetRunner, timeout: TimeInterval = 600,
                          onLive: @escaping @MainActor (Bool, Double?) -> Void = { _, _ in })
        -> Task<OpenSpeedTestWidgetRunner.Result, Error> {
        Task { try await runner.run(timeout: timeout, onLive: onLive) }
    }

    private func send(_ runner: OpenSpeedTestWidgetRunner, _ body: Any) {
        runner.userContentController(WKUserContentController(), didReceive: FakeScriptMessage(body))
    }

    private func outcome(_ task: Task<OpenSpeedTestWidgetRunner.Result, Error>) async -> Swift.Result<OpenSpeedTestWidgetRunner.Result, Error> {
        await task.result
    }

    func testDoneMessageResolvesTheRunWithTheScrapedNumbers() async throws {
        let runner = OpenSpeedTestWidgetRunner()
        let task = startRun(runner)
        await Task.yield()
        send(runner, ["type": "done", "down": 512.5, "up": 48.25, "ping": 11.0])
        let r = try await task.value
        XCTAssertEqual(r.down, 512.5)
        XCTAssertEqual(r.up, 48.25)
        XCTAssertEqual(r.ping, 11.0)
    }

    func testDoneWithoutAnUploadStillSucceeds() async throws {
        let runner = OpenSpeedTestWidgetRunner()
        let task = startRun(runner)
        await Task.yield()
        send(runner, ["type": "done", "down": 90.0])
        let r = try await task.value
        XCTAssertEqual(r.down, 90.0)
        XCTAssertNil(r.up)
        XCTAssertNil(r.ping)
    }

    func testDoneWithNoDownloadIsNoResult() async {
        for body: [String: Any] in [["type": "done", "down": 0.0], ["type": "done"]] {
            let runner = OpenSpeedTestWidgetRunner()
            let task = startRun(runner)
            await Task.yield()
            send(runner, body)
            guard case .failure(let e) = await outcome(task), case OpenSpeedTestWidgetRunner.RunError.noResult = e else {
                return XCTFail("expected noResult for \(body)")
            }
        }
    }

    func testStateMessagesStreamLiveProgress() async throws {
        let runner = OpenSpeedTestWidgetRunner()
        let seen = LockedBox<[String]>([])
        let task = startRun(runner) { isUpload, mbps in
            seen.mutate { $0.append("\(isUpload ? "up" : "down"):\(mbps.map { String(Int($0)) } ?? "nil")") }
        }
        await Task.yield()
        send(runner, ["type": "state", "status": "Download", "live": 250.0])
        send(runner, ["type": "state", "status": "Uploading", "live": 80.0])
        send(runner, ["type": "state", "status": "loading"])               // no live number yet
        send(runner, ["type": "mystery"])                                    // unknown types are ignored
        send(runner, "not a dictionary")                                     // malformed body is ignored
        send(runner, ["type": "done", "down": 100.0, "up": 50.0])
        _ = try await task.value
        XCTAssertEqual(seen.value, ["down:250", "up:80", "down:nil"])
        // After the run closes, late progress is dropped silently.
        send(runner, ["type": "state", "status": "Download", "live": 1.0])
        XCTAssertEqual(seen.value.count, 3)
    }

    func testCancelFailsAnInFlightRun() async {
        let runner = OpenSpeedTestWidgetRunner()
        let task = startRun(runner)
        await Task.yield()
        runner.cancel()
        guard case .failure(let e) = await outcome(task), case OpenSpeedTestWidgetRunner.RunError.cancelled = e else {
            return XCTFail("expected cancelled")
        }
        runner.cancel()   // idempotent once finished
    }

    func testCancelAfterSuccessJustClosesTheHost() async throws {
        let runner = OpenSpeedTestWidgetRunner()
        let task = startRun(runner)
        await Task.yield()
        send(runner, ["type": "done", "down": 10.0])
        _ = try await task.value
        runner.cancel()
        runner.windowWillClose(Notification(name: NSNotification.Name("test")))
    }

    func testWindowCloseFailsAnInFlightRun() async {
        let runner = OpenSpeedTestWidgetRunner()
        let task = startRun(runner)
        await Task.yield()
        runner.windowWillClose(Notification(name: NSNotification.Name("test")))
        guard case .failure(let e) = await outcome(task), case OpenSpeedTestWidgetRunner.RunError.cancelled = e else {
            return XCTFail("expected cancelled")
        }
    }

    func testTimeoutFailsTheRun() async {
        let runner = OpenSpeedTestWidgetRunner()
        let task = startRun(runner, timeout: 0.05)
        guard case .failure(let e) = await outcome(task), case OpenSpeedTestWidgetRunner.RunError.timedOut = e else {
            return XCTFail("expected timedOut")
        }
    }

    func testNavigationFailuresMapToLoadFailed() async {
        let webView = WKWebView()
        let error = URLError(.notConnectedToInternet)
        let provisional = { (runner: OpenSpeedTestWidgetRunner) in
            runner.webView(webView, didFailProvisionalNavigation: nil, withError: error)
        }
        let committed = { (runner: OpenSpeedTestWidgetRunner) in
            runner.webView(webView, didFail: nil, withError: error)
        }
        for fail in [provisional, committed] {
            let runner = OpenSpeedTestWidgetRunner()
            let task = startRun(runner)
            await Task.yield()
            fail(runner)
            guard case .failure(let e) = await outcome(task), case OpenSpeedTestWidgetRunner.RunError.loadFailed = e else {
                return XCTFail("expected loadFailed")
            }
        }
    }

    func testHostPageEmbedsTheWidgetOnTheOpenSpeedTestOrigin() {
        XCTAssertTrue(OpenSpeedTestWidgetRunner.hostHTML.contains("https://openspeedtest.com/speedtest?run"))
        XCTAssertEqual(OpenSpeedTestWidgetRunner.baseURL?.host, "openspeedtest.com")
    }
}
