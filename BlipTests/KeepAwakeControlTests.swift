import XCTest
@testable import Blip

// The Keep Awake controller paths the main suite doesn't reach: the row's toggle, remembered
// duration, the Accessibility prompt / refresh requests, failure notices, the password-prompt
// poll, plus the live IOKit assertion backend and the extras backends.

@MainActor
final class KeepAwakeControlTests: XCTestCase {
    private var defaults: UserDefaults!
    private var assertions: MockPowerAssertions!
    private var extras: MockExtras!
    private var clock = Date(timeIntervalSince1970: 3_000_000)

    private func make() -> KeepAwake {
        defaults = Fixtures.scratchDefaults("keepawake-control")
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
        defaults?.removePersistentDomain(forName: "com.blainemiller.BlipTests.keepawake-control")
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    // MARK: durations

    func testDurationIntervalsAndLabels() {
        XCTAssertEqual(KeepAwakeDuration.thirtyMinutes.interval, 1_800)
        XCTAssertEqual(KeepAwakeDuration.oneHour.interval, 3_600)
        XCTAssertEqual(KeepAwakeDuration.twoHours.interval, 7_200)
        XCTAssertEqual(KeepAwakeDuration.fourHours.interval, 14_400)
        XCTAssertNil(KeepAwakeDuration.indefinitely.interval)
        for d in KeepAwakeDuration.allCases {
            XCTAssertFalse(d.title.isEmpty, "\(d)")
            XCTAssertFalse(d.shortTitle.isEmpty, "\(d)")
        }
        XCTAssertEqual(KeepAwakeDuration.indefinitely.shortTitle, "∞")
    }

    // MARK: toggle + remembered duration

    func testToggleStartsWithTheLastPickedDurationAndStopsOnTheNextPress() {
        let k = make()
        XCTAssertEqual(k.lastDuration, .indefinitely, "nothing picked yet")
        k.toggle()
        XCTAssertTrue(k.isActive)
        XCTAssertNil(k.endsAt)
        k.toggle()
        XCTAssertFalse(k.isActive)

        k.start(.twoHours)
        k.stop()
        XCTAssertEqual(k.lastDuration, .twoHours, "the choice is remembered")
        k.toggle()
        XCTAssertEqual(k.endsAt, clock.addingTimeInterval(7_200))
        XCTAssertEqual(assertions.held.count, 1)
    }

    func testStopWhenIdleDoesNothingAndTickBeforeTheEndKeepsRunning() {
        let k = make()
        k.stop()
        XCTAssertEqual(assertions.created, 0)
        k.start(.thirtyMinutes)
        clock.addTimeInterval(60)
        k.tick()
        XCTAssertTrue(k.isActive)
        clock.addTimeInterval(1_800)
        k.tick()
        XCTAssertFalse(k.isActive)
        XCTAssertTrue(assertions.held.isEmpty, "the assertion is released with the session")
    }

    // MARK: requests to the extras backend

    func testJigglePermissionRequestAsksTheBackendToPrompt() async {
        let k = make()
        defaults.set(true, forKey: KeepAwake.Keys.jiggle)
        k.start(.oneHour)
        await settle()
        k.requestJigglePermission()
        await settle()
        XCTAssertEqual(extras.requests.last,
                       KeepAwakeExtrasRequest(lidClosed: false, jiggle: true, requestJigglePermission: true))
    }

    func testRefreshAsksForStateWithoutSwitchingAnythingOn() async {
        let k = make()
        extras.reply = KeepAwakeExtrasStatus(jiggle: false, jigglePermission: true)
        k.refreshExtras()
        await settle()
        XCTAssertEqual(extras.requests, [KeepAwakeExtrasRequest(lidClosed: false, jiggle: false)])
        XCTAssertTrue(k.extras.jigglePermission)

        extras.reply = nil                              // the backend went away
        k.refreshExtras()
        await settle()
        XCTAssertEqual(k.extras, KeepAwakeExtrasStatus(), "no backend answer resets the status")
    }

    func testWithoutABackendRequestsAreDroppedQuietly() async {
        let k = make()
        k.extrasBackend = nil
        defaults.set(true, forKey: KeepAwake.Keys.jiggle)
        k.start(.oneHour)
        k.refreshExtras()
        await settle()
        XCTAssertEqual(k.extras, KeepAwakeExtrasStatus())
        XCTAssertTrue(k.isActive)
    }

    func testAGenericLidFailureRevertsTheSwitchWithADifferentNotice() async {
        let k = make()
        defaults.set(true, forKey: KeepAwake.Keys.lidClosed)
        extras.reply = KeepAwakeExtrasStatus(lidError: "boom")
        k.start(.oneHour)
        await settle()
        XCTAssertFalse(defaults.bool(forKey: KeepAwake.Keys.lidClosed))
        let failureNotice = k.notice
        XCTAssertNotNil(failureNotice)

        let cancelled = make()
        defaults.set(true, forKey: KeepAwake.Keys.lidClosed)
        extras.reply = KeepAwakeExtrasStatus(lidError: "cancelled")
        cancelled.start(.oneHour)
        await settle()
        XCTAssertNotEqual(cancelled.notice, failureNotice, "a dismissed prompt reads differently from a failure")
    }

    func testAPendingPasswordPromptIsPolledUntilAnswered() async {
        let k = make()
        defaults.set(true, forKey: KeepAwake.Keys.lidClosed)
        extras.reply = KeepAwakeExtrasStatus(lidPending: true)
        k.start(.indefinitely)
        await settle()
        XCTAssertEqual(extras.requests.count, 1)
        XCTAssertTrue(k.extras.lidPending)

        extras.reply = KeepAwakeExtrasStatus(lidClosed: true)       // the user answered
        let polled = NSPredicate { [unowned self] _, _ in MainActor.assumeIsolated { self.extras.requests.count >= 2 } }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: polled, object: nil)], timeout: 30)
        await settle()
        XCTAssertTrue(k.extras.lidClosed)
        XCTAssertEqual(extras.requests.last, KeepAwakeExtrasRequest(lidClosed: true, jiggle: false))
    }

    func testBatteryUpdatesOnlyActWhenTheLowStateChanges() async {
        let k = make()
        defaults.set(true, forKey: KeepAwake.Keys.lidClosed)
        k.start(.indefinitely)
        await settle()
        let sent = extras.requests.count
        k.updateBattery(isPresent: true, onBattery: false, level: 80)     // still fine: no change
        k.updateBattery(isPresent: false, onBattery: true, level: 1)      // no battery: never "low"
        await settle()
        XCTAssertEqual(extras.requests.count, sent)
        XCTAssertNil(k.notice)
    }

    // MARK: real backends

    func testTheIOKitBackendHoldsAndReleasesRealAssertions() {
        let backend = IOKitPowerAssertions()
        let system = backend.create(keepDisplayOn: false, reason: "Blip unit test")
        let display = backend.create(keepDisplayOn: true, reason: "Blip unit test")
        XCTAssertNotNil(system)
        XCTAssertNotNil(display)
        XCTAssertNotEqual(system, display)
        if let system { backend.release(system) }
        if let display { backend.release(display) }
    }

    #if !APPSTORE
    func testTheLocalExtrasBackendReportsAnIdleStateForAnEmptyRequest() async {
        let status = await LocalKeepAwakeExtras().apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: false))
        XCTAssertEqual(status?.lidClosed, false)
        XCTAssertEqual(status?.lidPending, false)
        XCTAssertEqual(status?.jiggle, false)
        XCTAssertNil(status?.lidError)
    }

    func testTheDirectBuildWiresTheLocalBackendByDefault() {
        XCTAssertTrue(KeepAwake().extrasBackend is LocalKeepAwakeExtras)
    }
    #else
    func testTheStoreBackendNeedsAConnectedHelper() async {
        let backend = HelperKeepAwakeExtras(client: HelperClient())
        let status = await backend.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: false))
        XCTAssertNil(status, "no helper connection, no answer")
    }
    #endif
}
