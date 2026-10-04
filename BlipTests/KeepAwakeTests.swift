import XCTest
@testable import Blip

@MainActor
final class MockPowerAssertions: PowerAssertionBackend {
    private var nextID: UInt32 = 1
    private(set) var held: [UInt32: Bool] = [:]  // id → keeps display on
    private(set) var created = 0

    func create(keepDisplayOn: Bool, reason: String) -> UInt32? {
        defer { nextID += 1 }
        created += 1
        held[nextID] = keepDisplayOn
        return nextID
    }

    func release(_ id: UInt32) { held[id] = nil }
}

@MainActor
final class MockExtras: KeepAwakeExtrasBackend {
    var requests: [KeepAwakeExtrasRequest] = []
    var reply: KeepAwakeExtrasStatus? = KeepAwakeExtrasStatus()

    func apply(_ request: KeepAwakeExtrasRequest) async -> KeepAwakeExtrasStatus? {
        requests.append(request)
        return reply
    }
}

@MainActor
final class KeepAwakeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var assertions: MockPowerAssertions!
    private var extras: MockExtras!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func make() -> KeepAwake {
        defaults = Fixtures.scratchDefaults("keepawake")
        assertions = MockPowerAssertions()
        extras = MockExtras()
        let k = KeepAwake()
        k.defaults = defaults
        k.assertions = assertions
        k.extrasBackend = extras
        k.now = { [unowned self] in self.clock }
        return k
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: "com.blainemiller.BlipTests.keepawake")
    }

    /// Lets the controller's fire-and-forget extras Task finish.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testTimedSessionHoldsDisplayAssertionThenExpires() {
        let k = make()
        k.start(.oneHour)
        XCTAssertTrue(k.isActive)
        XCTAssertEqual(k.endsAt, clock.addingTimeInterval(3600))
        XCTAssertEqual(Array(assertions.held.values), [true], "display stays on by default")

        clock = clock.addingTimeInterval(3599)
        k.tick()
        XCTAssertTrue(k.isActive)

        clock = clock.addingTimeInterval(1)
        k.tick()
        XCTAssertFalse(k.isActive)
        XCTAssertNil(k.endsAt)
        XCTAssertTrue(assertions.held.isEmpty, "assertion released on expiry")
    }

    func testIndefiniteSessionNeverExpires() {
        let k = make()
        k.start(.indefinitely)
        XCTAssertNil(k.endsAt)
        clock = clock.addingTimeInterval(7 * 24 * 3600)
        k.tick()
        XCTAssertTrue(k.isActive)
        k.stop()
        XCTAssertTrue(assertions.held.isEmpty)
    }

    func testRestartReplacesTimerWithoutLeakingAssertions() {
        let k = make()
        k.start(.thirtyMinutes)
        k.start(.fourHours)
        XCTAssertEqual(k.endsAt, clock.addingTimeInterval(4 * 3600))
        XCTAssertEqual(assertions.held.count, 1)
    }

    func testDisplaySettingSwapsAssertionType() {
        let k = make()
        defaults.set(false, forKey: KeepAwake.Keys.keepDisplayOn)
        k.start(.indefinitely)
        XCTAssertEqual(Array(assertions.held.values), [false])

        defaults.set(true, forKey: KeepAwake.Keys.keepDisplayOn)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(Array(assertions.held.values), [true], "old assertion released, new one held")
    }

    func testExtrasFollowSettingsAndStopWithSession() async {
        let k = make()
        defaults.set(true, forKey: KeepAwake.Keys.lidClosed)
        defaults.set(true, forKey: KeepAwake.Keys.jiggle)
        k.start(.oneHour)
        await settle()
        XCTAssertEqual(extras.requests.last, KeepAwakeExtrasRequest(lidClosed: true, jiggle: true))

        k.stop()
        await settle()
        XCTAssertEqual(extras.requests.last, KeepAwakeExtrasRequest(lidClosed: false, jiggle: false))
    }

    func testNoExtrasTrafficWhenNoneWanted() async {
        let k = make()
        k.start(.oneHour)
        k.tick()
        k.stop()
        await settle()
        XCTAssertTrue(extras.requests.isEmpty)
    }

    func testTickIsAHeartbeatWhileExtrasAreOn() async {
        let k = make()
        defaults.set(true, forKey: KeepAwake.Keys.jiggle)
        k.start(.indefinitely)
        k.tick()
        k.tick()
        await settle()
        XCTAssertEqual(extras.requests.count, 3)
    }

    func testCancelledPasswordPromptRevertsLidSwitch() async {
        let k = make()
        defaults.set(true, forKey: KeepAwake.Keys.lidClosed)
        extras.reply = KeepAwakeExtrasStatus(lidError: "cancelled")
        k.start(.oneHour)
        await settle()
        XCTAssertFalse(defaults.bool(forKey: KeepAwake.Keys.lidClosed))
        XCTAssertNotNil(k.notice)
        XCTAssertTrue(k.isActive, "plain Keep Awake keeps running")
    }

    func testLowBatteryPausesLidModeOnly() async {
        let k = make()
        defaults.set(true, forKey: KeepAwake.Keys.lidClosed)
        defaults.set(true, forKey: KeepAwake.Keys.jiggle)
        k.start(.indefinitely)
        k.updateBattery(isPresent: true, onBattery: true, level: 9)
        await settle()
        XCTAssertEqual(extras.requests.last, KeepAwakeExtrasRequest(lidClosed: false, jiggle: true))
        XCTAssertNotNil(k.notice)

        k.updateBattery(isPresent: true, onBattery: false, level: 9)
        await settle()
        XCTAssertEqual(extras.requests.last, KeepAwakeExtrasRequest(lidClosed: true, jiggle: true),
                       "plugged in again: lid mode resumes")
    }

    func testDurationIntentStartsAndReportsEnd() async throws {
        let k = make()
        AppIntentsEnvironment.keepAwake = k
        defer { AppIntentsEnvironment.keepAwake = .shared }
        let intent = KeepMacAwakeIntent()
        intent.duration = .twoHours
        _ = try await intent.perform()
        XCTAssertEqual(k.endsAt, clock.addingTimeInterval(2 * 3600))
        _ = try await LetMacSleepIntent().perform()
        XCTAssertFalse(k.isActive)
    }

    func testPmsetParsing() {
        let on = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby 1\n"
        let off = "System-wide power settings:\n SleepDisabled\t\t0\n"
        XCTAssertTrue(LidClosedSleep.parseSleepDisabled(on))
        XCTAssertFalse(LidClosedSleep.parseSleepDisabled(off))
        XCTAssertFalse(LidClosedSleep.parseSleepDisabled("Currently in use:\n sleep 0\n"))
    }

    func testRootLoopPathsAreShellSafe() {
        XCTAssertTrue(LidClosedSleep.isShellSafe("/var/folders/ab/x_y-1/T/blip-lidclosed-ABC-123"))
        XCTAssertFalse(LidClosedSleep.isShellSafe("/tmp/a b"))
        XCTAssertFalse(LidClosedSleep.isShellSafe("/tmp/x';rm -rf /;'"))
        XCTAssertFalse(LidClosedSleep.isShellSafe("/tmp/$(id)"))
        XCTAssertEqual(LidClosedSleep.appleScriptEscaped(#"say "hi" \ there"#), #"say \"hi\" \\ there"#)
    }
}
