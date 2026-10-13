#if !APPSTORE
import XCTest
@testable import Blip

// The live edges of the Keep Awake extras that the fake-driven host tests don't touch: the
// mouse jiggler's timer lifecycle and idle probe, the real pmset reader, and the host's
// launch-time recovery hook. Nothing here prompts, posts an event or changes a power setting.

final class KeepAwakeSystemTests: XCTestCase {

    func testJigglerStartsAndStopsItsTimerIdempotently() {
        let jiggler = MouseJiggler()
        XCTAssertFalse(jiggler.isRunning)
        jiggler.start()
        jiggler.start()                                  // second start keeps the one timer
        XCTAssertTrue(jiggler.isRunning)
        jiggler.stop()
        XCTAssertFalse(jiggler.isRunning)
        jiggler.stop()
        XCTAssertFalse(jiggler.isRunning)
    }

    func testIdleSecondsIsNonNegativeAndPermissionIsReadable() {
        XCTAssertGreaterThanOrEqual(MouseJiggler.idleSeconds(), 0)
        XCTAssertEqual(MouseJiggler().permissionGranted, MouseJiggler.hasPermission)
        XCTAssertEqual(MouseJiggler.idleThreshold, 55)
    }

    func testRealPmsetOutputParsesToABoolean() {
        // On any Mac `pmset -g` runs; whatever it says must agree with the parser run on a re-read.
        let first = LidClosedSleep.systemSleepDisabled()
        let second = LidClosedSleep.systemSleepDisabled()
        XCTAssertEqual(first, second)
    }

    func testLiveSystemHooksAreWiredToTheRealPmset() {
        XCTAssertEqual(LidClosedSleep.System.live.sleepDisabled(), LidClosedSleep.systemSleepDisabled())
    }

    func testAFreshLidControllerIsInactiveAndShutdownWithoutAnEnableIsHarmless() {
        let lid = LidClosedSleep(ownerName: "Blip Test")
        XCTAssertFalse(lid.isActive)
        lid.disable()
        lid.shutdown()
        XCTAssertFalse(lid.isActive)
    }

    func testHostStatusStartsIdleAndRecoveryHookReturnsImmediately() {
        let host = KeepAwakeExtrasHost(lid: IdleLid(), jiggler: FakeJiggler())
        let status = host.status()
        XCTAssertFalse(status.lidClosed)
        XCTAssertFalse(status.lidPending)
        XCTAssertFalse(status.jiggle)
        XCTAssertFalse(host.isLeaseArmed)
        host.recoverAfterUncleanExit()
        host.stopAll()
    }
}

private final class IdleLid: LidClosedControlling, @unchecked Sendable {
    var isActive: Bool { false }
    func enable() -> Result<Void, LidClosedSleep.Failure> { .success(()) }
    func disable() {}
    func shutdown() {}
    func recoverAfterUncleanExit() {}
}
#endif
