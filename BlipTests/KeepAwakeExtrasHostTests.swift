#if !APPSTORE
import XCTest
@testable import Blip

// The closed-lid / mouse-jiggle extras host — what runs in-process in the direct build and
// inside Blip Helper for the App Store build — plus LidClosedSleep's root-loop bookkeeping,
// driven with fakes (no password prompt, no pmset, no posted events) and a manual clock.

final class FakeLid: LidClosedControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _active = false
    private var _enableCalls = 0
    private var _disableCalls = 0
    private var _shutdownCalls = 0
    /// Result of the next enable(); `gate` (if set) blocks enable() like a password prompt.
    var nextResult: Result<Void, LidClosedSleep.Failure> = .success(())
    var gate: DispatchSemaphore?

    var isActive: Bool { lock.withLock { _active } }
    var enableCalls: Int { lock.withLock { _enableCalls } }
    var disableCalls: Int { lock.withLock { _disableCalls } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }

    func enable() -> Result<Void, LidClosedSleep.Failure> {
        lock.withLock { _enableCalls += 1 }
        gate?.wait()
        let result = nextResult
        if case .success = result { lock.withLock { _active = true } }
        return result
    }
    func disable() { lock.withLock { _disableCalls += 1; _active = false } }
    func shutdown() { lock.withLock { _shutdownCalls += 1; _active = false } }
    func recoverAfterUncleanExit() {}
}

final class FakeJiggler: MouseJiggling, @unchecked Sendable {
    private let lock = NSLock()
    private var _running = false
    private var _prompts = 0
    var permissionGranted = true

    var isRunning: Bool { lock.withLock { _running } }
    var prompts: Int { lock.withLock { _prompts } }
    func promptForPermission() { lock.withLock { _prompts += 1 } }
    func start() { lock.withLock { _running = true } }
    func stop() { lock.withLock { _running = false } }
}

/// A clock tests advance by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 2_000_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

final class KeepAwakeExtrasHostTests: XCTestCase {
    private var lid: FakeLid!
    private var jiggler: FakeJiggler!
    private var clock: ManualClock!
    private var lidQueue: DispatchQueue!

    private func makeHost(lease: TimeInterval = 60) -> KeepAwakeExtrasHost {
        lid = FakeLid()
        jiggler = FakeJiggler()
        clock = ManualClock()
        lidQueue = DispatchQueue(label: "BlipTests.lidQueue")
        let clock = clock!
        // The lease timer is parked far out; tests call checkLease() with the manual clock.
        return KeepAwakeExtrasHost(lid: lid, jiggler: jiggler, leaseSeconds: lease,
                                   leaseCheckInterval: 3600, now: { clock.now }, lidQueue: lidQueue)
    }

    /// Waits for the (serial) prompt queue to finish the enable it was handed.
    private func drainLidQueue() { lidQueue.sync {} }

    func testLidRequestReportsPendingUntilThePromptIsAnswered() {
        let host = makeHost()
        lid.gate = DispatchSemaphore(value: 0)
        let first = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: false))
        XCTAssertTrue(first.lidPending, "apply never blocks on the password prompt")
        XCTAssertFalse(first.lidClosed)

        // A heartbeat while the prompt is still up must not start a second prompt.
        let second = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: false))
        XCTAssertTrue(second.lidPending)

        lid.gate?.signal()
        drainLidQueue()
        XCTAssertEqual(lid.enableCalls, 1)
        let after = host.status()
        XCTAssertFalse(after.lidPending)
        XCTAssertTrue(after.lidClosed)
        XCTAssertNil(after.lidError)
    }

    func testCancelledPromptIsReportedAndCoolsDownBeforeAskingAgain() {
        let host = makeHost()
        lid.nextResult = .failure(.cancelled)
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: false))
        drainLidQueue()
        XCTAssertEqual(host.status().lidError, "cancelled")

        clock.advance(5)
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: false))
        drainLidQueue()
        XCTAssertEqual(lid.enableCalls, 1, "no re-prompt inside the 10 s cooldown")

        clock.advance(6)   // 11 s after the failure
        lid.nextResult = .success(())
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: false))
        drainLidQueue()
        XCTAssertEqual(lid.enableCalls, 2)
        XCTAssertTrue(host.status().lidClosed)
    }

    func testFailureMessageSurfacesAndClearsWhenLidModeIsTurnedOff() {
        let host = makeHost()
        lid.nextResult = .failure(.failed("osascript failed"))
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: false))
        drainLidQueue()
        XCTAssertEqual(host.status().lidError, "osascript failed")

        let off = host.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: false))
        XCTAssertNil(off.lidError)
    }

    func testTurningLidModeOffDisablesAnActiveLid() {
        let host = makeHost()
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: false))
        drainLidQueue()
        XCTAssertTrue(lid.isActive)

        let off = host.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: false))
        XCTAssertEqual(lid.disableCalls, 1)
        XCTAssertFalse(off.lidClosed)
    }

    func testSwitchedOffWhilePromptWasUpDisablesOnSuccess() {
        let host = makeHost()
        lid.gate = DispatchSemaphore(value: 0)
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: false))
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: false))
        lid.gate?.signal()
        drainLidQueue()
        XCTAssertFalse(lid.isActive, "the late success is undone because nobody wants it any more")
        XCTAssertGreaterThanOrEqual(lid.disableCalls, 1)
    }

    func testJiggleFollowsRequestAndPermission() {
        let host = makeHost()
        XCTAssertTrue(host.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: true)).jiggle)
        XCTAssertFalse(host.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: false)).jiggle)

        jiggler.permissionGranted = false
        let denied = host.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: true, requestJigglePermission: true))
        XCTAssertFalse(denied.jiggle, "never jiggles without Accessibility permission")
        XCTAssertFalse(denied.jigglePermission)
        XCTAssertEqual(jiggler.prompts, 1)
    }

    func testLeaseExpiryPausesEverythingWhenHeartbeatsStop() {
        let host = makeHost(lease: 60)
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: true))
        drainLidQueue()
        XCTAssertTrue(lid.isActive)
        XCTAssertTrue(jiggler.isRunning)
        XCTAssertTrue(host.isLeaseArmed)

        clock.advance(59)
        host.checkLease()
        XCTAssertTrue(jiggler.isRunning, "still inside the lease")
        XCTAssertTrue(lid.isActive)

        clock.advance(2)   // 61 s without a heartbeat
        host.checkLease()
        XCTAssertFalse(jiggler.isRunning)
        XCTAssertFalse(lid.isActive)
        XCTAssertEqual(lid.shutdownCalls, 0, "pause keeps the root loop so the next request needn't prompt")
        XCTAssertFalse(host.isLeaseArmed)
    }

    func testHeartbeatsKeepTheLeaseAlive() {
        let host = makeHost(lease: 60)
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: true))
        for _ in 0..<5 {
            clock.advance(40)
            _ = host.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: true))
            host.checkLease()
        }
        XCTAssertTrue(jiggler.isRunning)
    }

    func testNoLeaseWhenNothingIsWanted() {
        let host = makeHost()
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: false, jiggle: false))
        XCTAssertFalse(host.isLeaseArmed)
    }

    func testStopAllShutsTheRootLoopDown() {
        let host = makeHost()
        _ = host.apply(KeepAwakeExtrasRequest(lidClosed: true, jiggle: true))
        drainLidQueue()
        host.stopAll()
        XCTAssertEqual(lid.shutdownCalls, 1)
        XCTAssertFalse(jiggler.isRunning)
        XCTAssertFalse(host.status().lidClosed)
    }
}

// MARK: - LidClosedSleep (root loop bookkeeping, recovery)

final class LidClosedSleepTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blip-lid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Recording fake for pmset + osascript.
    final class FakeSystem: @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [String] = []
        private var _prompts: [String] = []
        var sleepDisabled = false
        var result: Result<Void, LidClosedSleep.Failure> = .success(())
        var commands: [String] { lock.withLock { _commands } }
        var prompts: [String] { lock.withLock { _prompts } }

        var system: LidClosedSleep.System {
            LidClosedSleep.System(
                sleepDisabled: { [self] in lock.withLock { sleepDisabled } },
                runPrivileged: { [self] command, prompt in
                    lock.withLock { _commands.append(command); _prompts.append(prompt) }
                    return result
                })
        }
    }

    private func make(_ fake: FakeSystem) -> LidClosedSleep {
        LidClosedSleep(ownerName: "Blip", system: fake.system,
                       markerFile: dir.appendingPathComponent("marker"), sessionDirectory: dir)
    }

    private var marker: URL { dir.appendingPathComponent("marker") }

    private func sessionFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("blip-lidclosed-") }
    }

    func testEnableStartsAGuardedRootLoopAndWritesTheMarker() throws {
        let fake = FakeSystem()
        let lid = make(fake)
        guard case .success = lid.enable() else { return XCTFail("enable failed") }

        XCTAssertTrue(lid.isActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "marker survives a crash/reboot")
        let session = try XCTUnwrap(try sessionFiles().first)
        XCTAssertEqual(try String(contentsOf: session, encoding: .utf8), "1")

        let command = try XCTUnwrap(fake.commands.first)
        let switchPath = dir.appendingPathComponent(session.lastPathComponent).path
        XCTAssertTrue(command.contains("while [ -e \(switchPath) ]"), "the loop watches this session's switch file")
        XCTAssertTrue(command.contains("/bin/kill -0 \(getpid())"), "the loop dies with its owner")
        XCTAssertTrue(command.contains("/usr/bin/pmset -a disablesleep $want"))
        XCTAssertTrue(command.contains("/usr/bin/pmset -a disablesleep 0; /bin/rm -f \(switchPath)"),
                      "normal sleep is restored when the loop ends")
        XCTAssertTrue(command.hasPrefix("/bin/sh -c '") && command.hasSuffix("' >/dev/null 2>&1 &"),
                      "runs detached so the prompt returns")
        XCTAssertTrue(fake.prompts.first?.contains("Blip needs your password") == true)
    }

    func testDisableFlipsTheSwitchWithoutPromptingAndReenableReusesTheLoop() throws {
        let fake = FakeSystem()
        let lid = make(fake)
        _ = lid.enable()
        let session = try XCTUnwrap(try sessionFiles().first)

        lid.disable()
        XCTAssertFalse(lid.isActive)
        XCTAssertEqual(try String(contentsOf: session, encoding: .utf8), "0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        // The loop applies the switch; on re-enable pmset already reports it, so no prompt.
        fake.sleepDisabled = true
        guard case .success = lid.enable() else { return XCTFail("re-enable failed") }
        XCTAssertEqual(fake.commands.count, 1, "toggling back on never asks for the password again")
        XCTAssertEqual(try String(contentsOf: session, encoding: .utf8), "1")
        XCTAssertTrue(lid.isActive)
    }

    func testShutdownRemovesTheSwitchFileSoTheLoopExits() throws {
        let fake = FakeSystem()
        let lid = make(fake)
        _ = lid.enable()
        lid.shutdown()
        XCTAssertTrue(try sessionFiles().isEmpty)
        XCTAssertFalse(lid.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancelledPromptLeavesNothingBehind() throws {
        let fake = FakeSystem()
        fake.result = .failure(.cancelled)
        let lid = make(fake)
        guard case .failure(.cancelled) = lid.enable() else { return XCTFail("expected cancelled") }
        XCTAssertFalse(lid.isActive)
        XCTAssertTrue(try sessionFiles().isEmpty, "the unused session file is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRecoveryWithMarkerAndSleepStillDisabledRestoresNormalSleep() {
        let fake = FakeSystem()
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        fake.sleepDisabled = true
        make(fake).recoverAfterUncleanExit()
        XCTAssertEqual(fake.commands, ["/usr/bin/pmset -a disablesleep 0"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRecoveryKeepsMarkerWhenTheUserDeclines() {
        let fake = FakeSystem()
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        fake.sleepDisabled = true
        fake.result = .failure(.cancelled)
        make(fake).recoverAfterUncleanExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "asks again next launch")
    }

    func testRecoveryWithStaleMarkerJustClearsIt() {
        let fake = FakeSystem()
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        fake.sleepDisabled = false
        make(fake).recoverAfterUncleanExit()
        XCTAssertTrue(fake.commands.isEmpty, "no prompt when sleep is already normal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRecoveryWithoutMarkerDoesNothing() {
        let fake = FakeSystem()
        fake.sleepDisabled = true   // e.g. the user ran pmset themselves — not ours to undo
        make(fake).recoverAfterUncleanExit()
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(LidClosedSleep.appleScriptEscaped(#"a"b"#), #"a\"b"#)
        XCTAssertEqual(LidClosedSleep.appleScriptEscaped(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(LidClosedSleep.appleScriptEscaped(#"\""#), #"\\\""#, "backslash first, then quote")
        XCTAssertEqual(LidClosedSleep.appleScriptEscaped("plain"), "plain")
    }

    func testShellSafetyRejectsEveryInjectionShape() {
        for bad in ["", "/tmp/a;b", "/tmp/`id`", "/tmp/$(id)", "/tmp/a b", "/tmp/a\nb", "/tmp/a'b",
                    "/tmp/a\"b", "/tmp/a|b", "/tmp/a&b", "/tmp/ü"] {
            XCTAssertFalse(LidClosedSleep.isShellSafe(bad), bad)
        }
        XCTAssertTrue(LidClosedSleep.isShellSafe(dir.appendingPathComponent("blip-lidclosed-ABC").path))
    }
}
#endif
