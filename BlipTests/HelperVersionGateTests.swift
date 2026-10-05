import XCTest
@testable import Blip

// App Store build: the closed-lid / jiggle switches only appear for a helper that serves
// `keepAwake` (2.0.5+), and Settings flags a helper older than the app. Versions compare
// numerically — a lexical compare would call 2.0.10 older than 2.0.5.

final class HelperVersionGateTests: XCTestCase {

    func testKeepAwakeStateNeedsAConnectedHelper() {
        XCTAssertEqual(HelperVersionGate.keepAwakeState(connected: false, helperVersion: "9.9.9"), .absent)
    }

    func testKeepAwakeStateByVersion() {
        XCTAssertEqual(HelperVersionGate.keepAwakeState(connected: true, helperVersion: "2.0.5"), .ready)
        XCTAssertEqual(HelperVersionGate.keepAwakeState(connected: true, helperVersion: "2.0.6"), .ready)
        XCTAssertEqual(HelperVersionGate.keepAwakeState(connected: true, helperVersion: "2.0.10"), .ready, "numeric, not lexical")
        XCTAssertEqual(HelperVersionGate.keepAwakeState(connected: true, helperVersion: "3"), .ready)
        XCTAssertEqual(HelperVersionGate.keepAwakeState(connected: true, helperVersion: "2.0.4"), .outdated)
        XCTAssertEqual(HelperVersionGate.keepAwakeState(connected: true, helperVersion: "1.9.99"), .outdated)
        XCTAssertEqual(HelperVersionGate.keepAwakeState(connected: true, helperVersion: nil), .outdated, "pre-versioning helper")
        XCTAssertEqual(HelperVersionGate.keepAwakeState(connected: true, helperVersion: ""), .outdated)
    }

    func testHelperOutdatedComparedWithTheApp() {
        XCTAssertFalse(HelperVersionGate.isOutdated(installed: "1.0", app: "2.0.6", connected: false),
                       "a helper that isn't running isn't 'outdated'")
        XCTAssertTrue(HelperVersionGate.isOutdated(installed: nil, app: "2.0.6", connected: true))
        XCTAssertTrue(HelperVersionGate.isOutdated(installed: "", app: "2.0.6", connected: true))
        XCTAssertTrue(HelperVersionGate.isOutdated(installed: "2.0.5", app: "2.0.6", connected: true))
        XCTAssertTrue(HelperVersionGate.isOutdated(installed: "1.4.7", app: "1.5.0", connected: true))
        XCTAssertFalse(HelperVersionGate.isOutdated(installed: "2.0.6", app: "2.0.6", connected: true))
        XCTAssertFalse(HelperVersionGate.isOutdated(installed: "2.0.10", app: "2.0.6", connected: true))
        XCTAssertFalse(HelperVersionGate.isOutdated(installed: "2.1", app: "2.0.6", connected: true))
    }

    @MainActor
    func testDirectBuildAlwaysOffersTheExtras() {
        #if APPSTORE
        // A fresh monitor's helper client has never connected.
        XCTAssertEqual(keepAwakeHelperState(SystemMonitor(defaults: Fixtures.scratchDefaults("gate"))), .absent)
        XCTAssertEqual(keepAwakeHelperState(nil), .absent)
        #else
        XCTAssertEqual(keepAwakeHelperState(nil), .ready, "the direct build runs the extras itself")
        XCTAssertTrue(keepAwakeExtrasAvailable(nil))
        XCTAssertFalse(keepAwakeHelperNeedsUpdate(nil))
        #endif
    }
}
