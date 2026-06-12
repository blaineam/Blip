import XCTest
@testable import Blip

@MainActor
final class TracerouteIntentTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = Fixtures.scratchDefaults("traceroute")
        AppIntentsEnvironment.defaults = defaults
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "com.blainemiller.BlipTests.traceroute")
        AppIntentsEnvironment.defaults = .standard
        AppIntentsEnvironment.tracerouteControl = nil
        AppIntentsEnvironment.openTracerouteWindow = nil
    }

    // MARK: Host validation (pure)

    func testHostValidation() {
        XCTAssertTrue(HostValidation.isValid("1.1.1.1"))
        XCTAssertTrue(HostValidation.isValid("example.com"))
        XCTAssertTrue(HostValidation.isValid("my-host.local"))
        XCTAssertTrue(HostValidation.isValid("2606:4700:4700::1111"))

        XCTAssertFalse(HostValidation.isValid(""))
        XCTAssertFalse(HostValidation.isValid("host name"))            // whitespace
        XCTAssertFalse(HostValidation.isValid("host;rm -rf /"))       // shell metachars
        XCTAssertFalse(HostValidation.isValid("host$(whoami)"))
        XCTAssertFalse(HostValidation.isValid(String(repeating: "a", count: 254)))  // too long
    }

    // MARK: Parameter validation (pure)

    func testDurationClamping() {
        XCTAssertEqual(TracerouteParameters.clampedDuration(0), 3)
        XCTAssertEqual(TracerouteParameters.clampedDuration(-5), 3)
        XCTAssertEqual(TracerouteParameters.clampedDuration(10), 10)
        XCTAssertEqual(TracerouteParameters.clampedDuration(120), 120)
        XCTAssertEqual(TracerouteParameters.clampedDuration(9_999), 120)
    }

    func testHostResolutionPrecedence() {
        typealias P = TracerouteParameters
        XCTAssertEqual(P.resolveHost(parameter: "example.com", settingsTarget: "set.com", pingTarget: "8.8.8.8"),
                       "example.com")
        XCTAssertEqual(P.resolveHost(parameter: "  spaced.com  ", settingsTarget: nil, pingTarget: nil),
                       "spaced.com")
        XCTAssertEqual(P.resolveHost(parameter: nil, settingsTarget: "set.com", pingTarget: "8.8.8.8"),
                       "set.com")
        XCTAssertEqual(P.resolveHost(parameter: "", settingsTarget: "", pingTarget: "8.8.8.8"),
                       "8.8.8.8")
        XCTAssertEqual(P.resolveHost(parameter: nil, settingsTarget: nil, pingTarget: nil),
                       "1.1.1.1")
    }

    // MARK: Summary (pure)

    func testSummaryWithLoss() {
        let hops = [
            Fixtures.hop(1, host: "192.168.1.1", sent: 10, recv: 10, avg: 1.2),
            Fixtures.hop(2, host: "10.0.0.1", sent: 10, recv: 7, avg: 8.4),
            Fixtures.hop(3, host: "1.1.1.1", sent: 10, recv: 10, avg: 12.3),
        ]
        let s = TracerouteSummary.make(hops: hops, host: "1.1.1.1")
        XCTAssertEqual(s, "Traceroute to 1.1.1.1: 3 hops, final hop 1.1.1.1 avg 12.3 ms, worst loss 30% at hop 2 (10.0.0.1)")
    }

    func testSummaryNoLoss() {
        let hops = [
            Fixtures.hop(1, host: "192.168.1.1", sent: 5, recv: 5, avg: 1.0),
            Fixtures.hop(2, host: "1.1.1.1", sent: 5, recv: 5, avg: 9.5),
        ]
        let s = TracerouteSummary.make(hops: hops, host: "one.one.one.one")
        XCTAssertEqual(s, "Traceroute to one.one.one.one: 2 hops, final hop 1.1.1.1 avg 9.5 ms, no packet loss")
    }

    func testSummaryEmpty() {
        XCTAssertEqual(TracerouteSummary.make(hops: [], host: "example.com"),
                       "Traceroute to example.com: no replies yet.")
    }

    // MARK: Run intent — happy path with a mocked MTR session (3 s sample)

    func testRunTracerouteSamplesAndStops() async throws {
        var started: String?
        var stopped = false
        let hops = [
            Fixtures.hop(1, host: "192.168.1.1", sent: 3, recv: 3, avg: 1.1),
            Fixtures.hop(2, host: "1.1.1.1", sent: 3, recv: 3, avg: 11.5),
        ]
        AppIntentsEnvironment.tracerouteControl = TracerouteControl(
            start: { host in started = host },
            stop: { stopped = true },
            poll: { (hops, true) }
        )

        let intent = RunTracerouteIntent()
        intent.host = nil                       // falls back to Settings target
        intent.duration = 3
        intent.keepRunning = false
        defaults.set("one.one.one.one", forKey: "tracerouteTarget")

        let result = try await intent.perform()
        XCTAssertEqual(started, "one.one.one.one")
        XCTAssertTrue(stopped, "session must stop when keepRunning is false")
        XCTAssertTrue(result.value!.contains("2 hops"))
        XCTAssertTrue(result.value!.contains("no packet loss"))
    }

    func testRunTracerouteKeepRunningLeavesSessionAlive() async throws {
        var stopped = false
        AppIntentsEnvironment.tracerouteControl = TracerouteControl(
            start: { _ in },
            stop: { stopped = true },
            poll: { ([Fixtures.hop(1, host: "10.0.0.1", sent: 3, recv: 3, avg: 2.0)], true) }
        )
        let intent = RunTracerouteIntent()
        intent.host = "10.0.0.1"
        intent.duration = 3
        intent.keepRunning = true
        _ = try await intent.perform()
        XCTAssertFalse(stopped, "keepRunning must leave the MTR session active")
    }

    // MARK: Run intent — invalid host fails fast (no sleep, mock untouched)

    func testRunTracerouteRejectsInvalidHost() async {
        AppIntentsEnvironment.tracerouteControl = TracerouteControl(
            start: { _ in XCTFail("must not start with an invalid host") },
            stop: {},
            poll: { ([], false) }
        )
        let intent = RunTracerouteIntent()
        intent.host = "bad host; rm"
        intent.duration = 3
        intent.keepRunning = false
        do {
            _ = try await intent.perform()
            XCTFail("expected invalidHost")
        } catch let error as BlipIntentError {
            guard case .invalidHost = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRunTracerouteWithoutServicesThrows() async {
        AppIntentsEnvironment.tracerouteControl = nil
        let intent = RunTracerouteIntent()
        intent.host = "1.1.1.1"
        intent.duration = 3
        intent.keepRunning = false
        do {
            _ = try await intent.perform()
            XCTFail("expected appNotReady")
        } catch let error as BlipIntentError {
            guard case .appNotReady = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: Stop intent

    func testStopTraceroute() async throws {
        var stopped = false
        AppIntentsEnvironment.tracerouteControl = TracerouteControl(
            start: { _ in },
            stop: { stopped = true },
            poll: { ([], false) }
        )
        _ = try await StopTracerouteIntent().perform()
        XCTAssertTrue(stopped)
    }

    // MARK: Open window intent

    func testOpenWindowPreTargetsHost() async throws {
        var opened: String??
        var started: String?
        AppIntentsEnvironment.openTracerouteWindow = { host in opened = host }
        AppIntentsEnvironment.tracerouteControl = TracerouteControl(
            start: { host in started = host },
            stop: {},
            poll: { ([], true) }
        )

        let intent = OpenTracerouteWindowIntent()
        intent.host = " example.com "
        _ = try await intent.perform()
        XCTAssertEqual(opened, "example.com")
        XCTAssertEqual(started, "example.com")
    }

    /// QA build 52: the map opened but sat idle on "Enter a host and press
    /// Start." Opening with a host must auto-START the trace, and it must be
    /// running BEFORE the window opens so the first poll already sees it live.
    func testOpenWindowAutoStartsTraceBeforeOpening() async throws {
        var events: [String] = []
        AppIntentsEnvironment.openTracerouteWindow = { host in events.append("open:\(host ?? "-")") }
        AppIntentsEnvironment.tracerouteControl = TracerouteControl(
            start: { host in events.append("start:\(host)") },
            stop: { events.append("stop") },
            poll: { ([], true) }
        )

        let intent = OpenTracerouteWindowIntent()
        intent.host = "1.1.1.1"
        _ = try await intent.perform()
        XCTAssertEqual(events, ["start:1.1.1.1", "open:1.1.1.1"])
    }

    func testOpenWindowWithoutHost() async throws {
        var openCalls = 0
        var lastHost: String?
        AppIntentsEnvironment.openTracerouteWindow = { host in
            openCalls += 1
            lastHost = host
        }
        // No host → just open: the MTR session must NOT be touched.
        AppIntentsEnvironment.tracerouteControl = TracerouteControl(
            start: { _ in XCTFail("must not auto-start without a host") },
            stop: { XCTFail("must not stop without a host") },
            poll: { ([], false) }
        )
        let intent = OpenTracerouteWindowIntent()
        intent.host = nil
        _ = try await intent.perform()
        XCTAssertEqual(openCalls, 1)
        XCTAssertNil(lastHost)
    }

    func testOpenWindowWithHostRequiresTracerouteControl() async {
        AppIntentsEnvironment.openTracerouteWindow = { _ in XCTFail("must not open when the trace can't start") }
        AppIntentsEnvironment.tracerouteControl = nil
        let intent = OpenTracerouteWindowIntent()
        intent.host = "1.1.1.1"
        do {
            _ = try await intent.perform()
            XCTFail("expected appNotReady")
        } catch let error as BlipIntentError {
            guard case .appNotReady = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testOpenWindowRejectsInvalidHost() async {
        AppIntentsEnvironment.openTracerouteWindow = { _ in XCTFail("must not open with invalid host") }
        AppIntentsEnvironment.tracerouteControl = TracerouteControl(
            start: { _ in XCTFail("must not start with invalid host") },
            stop: {},
            poll: { ([], false) }
        )
        let intent = OpenTracerouteWindowIntent()
        intent.host = "nope nope"
        do {
            _ = try await intent.perform()
            XCTFail("expected invalidHost")
        } catch let error as BlipIntentError {
            guard case .invalidHost = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
