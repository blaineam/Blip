#if !APPSTORE
import Foundation
import CoreGraphics

// MARK: - Keep Awake extras (closed lid + mouse jiggle)
//
// Both need more than a power assertion, so neither is compiled into the App
// Store build: the direct download runs them in-process, and the App Store
// build asks Blip Helper (unsandboxed, distributed outside the store) to run
// them over the existing TOTP channel. The App Store binary itself never
// escalates privileges or posts events.

/// Keeps a MacBook awake with its lid closed.
///
/// A power assertion can't do this — closing the lid sleeps the Mac unless
/// `pmset disablesleep` is set, which needs root. One administrator prompt
/// starts a small root shell loop that lives as long as the owning process
/// (Blip, or Blip Helper) and follows a one-byte switch file: "1" sets
/// `disablesleep`, anything else clears it. Toggling lid-closed mode off and
/// on again just rewrites the switch, so the password is asked once per launch,
/// not on every toggle. The loop only ever runs those two fixed `pmset`
/// commands, and when the switch file disappears or the owner quits or
/// crashes it restores normal sleep and exits.
///
/// `disablesleep` survives a reboot, which the loop doesn't, so a marker file
/// records that it was on; `recoverAfterUncleanExit()` restores it on the next
/// launch.
final class LidClosedSleep: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case cancelled
        case failed(String)
    }

    /// The two system touch points: reading `pmset -g` and running an administrator
    /// command through osascript. Swappable so the state machine can be unit-tested
    /// without a password prompt or a real `pmset`.
    struct System: Sendable {
        var sleepDisabled: @Sendable () -> Bool
        var runPrivileged: @Sendable (_ command: String, _ prompt: String) -> Result<Void, Failure>

        static let live = System(sleepDisabled: { LidClosedSleep.systemSleepDisabled() },
                                 runPrivileged: { LidClosedSleep.runPrivileged($0, prompt: $1) })
    }

    private let lock = NSLock()
    /// The switch file the root loop watches; nil until the first prompt succeeds.
    private var sentinel: URL?
    private var on = false
    private let ownerName: String
    private let system: System
    private let markerFile: URL?
    private let sessionDirectory: URL?

    /// - Parameter ownerName: shown in the password prompt ("Blip", "Blip Helper").
    init(ownerName: String) {
        self.ownerName = ownerName
        self.system = .live
        self.markerFile = nil
        self.sessionDirectory = nil
    }

    /// Test seam: a fake system, plus where the unclean-exit marker and the session
    /// (switch) file live.
    init(ownerName: String, system: System, markerFile: URL, sessionDirectory: URL) {
        self.ownerName = ownerName
        self.system = system
        self.markerFile = markerFile
        self.sessionDirectory = sessionDirectory
    }

    /// True while the root loop is holding lid-closed sleep off.
    var isActive: Bool {
        lock.withLock { on && sentinel.map { FileManager.default.fileExists(atPath: $0.path) } == true }
    }

    /// Turns lid-closed mode on. The first call prompts for an administrator
    /// password and starts the root loop; later calls flip its switch without
    /// prompting. Can block on the prompt — call off the main thread.
    func enable() -> Result<Void, Failure> {
        if isActive { return .success(()) }
        if let file = lock.withLock({ sentinel }), FileManager.default.fileExists(atPath: file.path) {
            Self.setSwitch(file, true)
            // The loop polls every 2 s. If it never applies the switch it was
            // killed out from under us, so fall through and start a fresh one.
            for _ in 0..<8 {
                if system.sleepDisabled() {
                    lock.withLock { on = true }
                    writeMarker()
                    return .success(())
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            try? FileManager.default.removeItem(at: file)
            lock.withLock { sentinel = nil }
        }

        let dir = sessionDirectory ?? FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("blip-lidclosed-\(UUID().uuidString)")
        guard Self.isShellSafe(file.path) else { return .failure(.failed("Unsafe temporary path")) }
        guard FileManager.default.createFile(atPath: file.path, contents: Data("1".utf8), attributes: [.posixPermissions: 0o600]) else {
            return .failure(.failed("Couldn't create the session file"))
        }

        let s = file.path
        let loop = "cur=; while [ -e \(s) ] && /bin/kill -0 \(getpid()) 2>/dev/null; do "
            + "if [ \"$(/bin/cat \(s) 2>/dev/null)\" = 1 ]; then want=1; else want=0; fi; "
            + "if [ \"$want\" != \"$cur\" ]; then /usr/bin/pmset -a disablesleep $want; cur=$want; fi; "
            + "/bin/sleep 2; done; "
            + "/usr/bin/pmset -a disablesleep 0; /bin/rm -f \(s)"
        let command = "/bin/sh -c '\(loop)' >/dev/null 2>&1 &"
        let prompt = "\(ownerName) needs your password to keep this Mac awake with the lid closed. It asks once while \(ownerName) is running; normal sleep comes back when Keep Awake ends or \(ownerName) quits."

        switch system.runPrivileged(command, prompt) {
        case .success:
            lock.withLock { sentinel = file; on = true }
            writeMarker()
            return .success(())
        case .failure(let failure):
            try? FileManager.default.removeItem(at: file)
            return .failure(failure)
        }
    }

    /// Turns lid-closed mode off: the root loop restores normal sleep within
    /// ~2 s but stays up, so turning it back on doesn't prompt. Never prompts.
    func disable() {
        let file: URL? = lock.withLock {
            defer { on = false }
            return sentinel
        }
        guard let file else { return }
        Self.setSwitch(file, false)
        removeMarker()
    }

    /// Turns lid-closed mode off and ends the root loop (Blip or the helper
    /// is quitting). The next enable prompts again.
    func shutdown() {
        let file: URL? = lock.withLock {
            defer { sentinel = nil; on = false }
            return sentinel
        }
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
        removeMarker()
    }

    private static func setSwitch(_ file: URL, _ on: Bool) {
        try? Data((on ? "1" : "0").utf8).write(to: file)
    }

    /// If a previous run left `disablesleep` on (reboot, forced kill of the
    /// root loop), prompt once to turn lid-closed sleep back on. Call at launch,
    /// off the main thread.
    func recoverAfterUncleanExit() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        guard !isActive else { return }
        guard system.sleepDisabled() else {
            removeMarker()
            return
        }
        let prompt = "\(ownerName) kept this Mac awake with the lid closed before it last quit. Enter your password to turn normal lid-closed sleep back on."
        if case .success = system.runPrivileged("/usr/bin/pmset -a disablesleep 0", prompt) {
            removeMarker()
        }
    }

    // MARK: Helpers

    /// `pmset -g` lists `SleepDisabled 1` while lid-closed sleep is off.
    static func systemSleepDisabled() -> Bool {
        guard let output = run("/usr/bin/pmset", ["-g"]).output else { return false }
        return parseSleepDisabled(output)
    }

    static func parseSleepDisabled(_ pmsetOutput: String) -> Bool {
        for line in pmsetOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.first == "SleepDisabled", fields.count >= 2 {
                return fields[1] == "1"
            }
        }
        return false
    }

    /// The loop is interpolated into a root shell, so only plain path
    /// characters are allowed (temporaryDirectory is /var/folders/…/T/).
    static func isShellSafe(_ path: String) -> Bool {
        !path.isEmpty && path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }
    }

    private static func runPrivileged(_ command: String, prompt: String) -> Result<Void, Failure> {
        let script = "do shell script \"\(appleScriptEscaped(command))\" with prompt \"\(appleScriptEscaped(prompt))\" with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", script])
        if result.status == 0 { return .success(()) }
        if (result.error ?? "").contains("-128") { return .failure(.cancelled) }
        return .failure(.failed(result.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "osascript failed"))
    }

    static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, nil, error.localizedDescription) }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }

    /// Present while lid-closed sleep is (or was, before a crash) held off.
    var markerURL: URL {
        if let markerFile { return markerFile }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.blainemiller.Blip")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lid-closed-sleep-disabled")
    }

    private func writeMarker() {
        FileManager.default.createFile(atPath: markerURL.path, contents: nil)
    }

    private func removeMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}

/// Nudges the pointer one pixel and straight back once the user has been idle
/// for `idleThreshold`, so chat and meeting apps don't mark them away. It
/// never moves the pointer while someone is using the Mac. Posting events
/// needs the Accessibility permission for the process that posts them.
final class MouseJiggler: @unchecked Sendable {
    static let idleThreshold: TimeInterval = 55

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.blainemiller.Blip.jiggler")

    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    /// Shows the system prompt that sends the user to Accessibility settings.
    static func requestPermission() { _ = CGRequestPostEventAccess() }

    var isRunning: Bool { lock.withLock { timer != nil } }

    func start() {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 15)
            t.setEventHandler { Self.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    private static func tick() {
        guard idleSeconds() >= idleThreshold, hasPermission else { return }
        nudge()
    }

    /// Seconds since the last keyboard, pointer or scroll input.
    static func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private static func nudge() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for point in [CGPoint(x: location.x + 1, y: location.y), location] {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }
}

/// What the extras host needs from the lid-closed controller (LidClosedSleep in
/// production; a fake in tests).
protocol LidClosedControlling: AnyObject, Sendable {
    var isActive: Bool { get }
    func enable() -> Result<Void, LidClosedSleep.Failure>
    func disable()
    func shutdown()
    func recoverAfterUncleanExit()
}

extension LidClosedSleep: LidClosedControlling {}

/// What the extras host needs from the jiggler (MouseJiggler in production).
protocol MouseJiggling: AnyObject, Sendable {
    var isRunning: Bool { get }
    var permissionGranted: Bool { get }
    func promptForPermission()
    func start()
    func stop()
}

extension MouseJiggler: MouseJiggling {
    var permissionGranted: Bool { Self.hasPermission }
    func promptForPermission() { Self.requestPermission() }
}

/// Runs the extras for whoever asks — Blip itself in the direct build, or the
/// helper on behalf of the App Store build. Requests double as a heartbeat:
/// if none arrives for `leaseSeconds`, everything stops, so a client that
/// quits or crashes can't leave the lid-closed mode or the jiggler running.
final class KeepAwakeExtrasHost: @unchecked Sendable {
    private let lock = NSLock()
    private let lid: LidClosedControlling
    private let jiggler: MouseJiggling
    private let leaseSeconds: TimeInterval
    /// After a failed or cancelled password prompt, don't prompt again for this long.
    private let failureCooldown: TimeInterval
    private let leaseCheckInterval: TimeInterval
    private let now: @Sendable () -> Date
    /// Where the (blocking) password prompt runs.
    private let lidQueue: DispatchQueue
    private var desiredLid = false
    private var lidPending = false
    private var lidError: String?
    private var lidFailedAt: Date?
    private var lastHeartbeat = Date.distantPast
    private var leaseTimer: DispatchSourceTimer?

    convenience init(ownerName: String, leaseSeconds: TimeInterval = 60) {
        self.init(lid: LidClosedSleep(ownerName: ownerName), jiggler: MouseJiggler(),
                  leaseSeconds: leaseSeconds)
    }

    /// Designated init; the extra parameters are test seams with production defaults.
    init(lid: LidClosedControlling, jiggler: MouseJiggling,
         leaseSeconds: TimeInterval = 60,
         failureCooldown: TimeInterval = 10,
         leaseCheckInterval: TimeInterval = 10,
         now: @escaping @Sendable () -> Date = { Date() },
         lidQueue: DispatchQueue = .global(qos: .userInitiated)) {
        self.lid = lid
        self.jiggler = jiggler
        self.leaseSeconds = leaseSeconds
        self.failureCooldown = failureCooldown
        self.leaseCheckInterval = leaseCheckInterval
        self.now = now
        self.lidQueue = lidQueue
    }

    /// Applies the requested state and returns the current one. Never blocks
    /// on the password prompt: turning lid mode on reports `lidPending` until
    /// the prompt is answered, and the next request picks up the result.
    func apply(_ request: KeepAwakeExtrasRequest) -> KeepAwakeExtrasStatus {
        if request.requestJigglePermission { jiggler.promptForPermission() }

        if request.jiggle && jiggler.permissionGranted { jiggler.start() } else { jiggler.stop() }

        var startLid = false
        let current = now()
        lock.withLock {
            lastHeartbeat = current
            desiredLid = request.lidClosed
            if !request.lidClosed { lidError = nil }
            let cooledDown = lidFailedAt.map { current.timeIntervalSince($0) > failureCooldown } ?? true
            if request.lidClosed, !lidPending, cooledDown, !lid.isActive {
                lidPending = true
                lidError = nil
                startLid = true
            }
        }
        if startLid { enableLid() }
        if !request.lidClosed && lid.isActive { lid.disable() }

        if request.lidClosed || request.jiggle { startLease() }
        return status()
    }

    /// Blip or the helper is quitting: switch everything off and end the root loop.
    func stopAll() {
        lock.withLock { desiredLid = false }
        jiggler.stop()
        lid.shutdown()
    }

    /// The client stopped asking (Keep Awake ended, or the app crashed): switch
    /// everything off but keep the root loop, so the next lid-closed request
    /// doesn't ask for the password again. The loop still dies with this process.
    private func pauseAll() {
        lock.withLock { desiredLid = false }
        jiggler.stop()
        lid.disable()
    }

    func recoverAfterUncleanExit() {
        DispatchQueue.global(qos: .utility).async { [lid] in lid.recoverAfterUncleanExit() }
    }

    func status() -> KeepAwakeExtrasStatus {
        lock.withLock {
            KeepAwakeExtrasStatus(lidClosed: lid.isActive, lidPending: lidPending, lidError: lidError,
                                  jiggle: jiggler.isRunning, jigglePermission: jiggler.permissionGranted)
        }
    }

    private func enableLid() {
        lidQueue.async { [self] in
            let result = lid.enable()
            let failedAt = now()
            let stillWanted = lock.withLock { () -> Bool in
                lidPending = false
                switch result {
                case .success:
                    lidFailedAt = nil
                case .failure(.cancelled):
                    lidFailedAt = failedAt
                    lidError = "cancelled"
                case .failure(.failed(let message)):
                    lidFailedAt = failedAt
                    lidError = message
                }
                return desiredLid
            }
            // Switched off while the password prompt was up.
            if case .success = result, !stillWanted { lid.disable() }
        }
    }

    private func startLease() {
        lock.withLock {
            guard leaseTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + leaseCheckInterval, repeating: leaseCheckInterval)
            t.setEventHandler { [weak self] in self?.checkLease() }
            t.resume()
            leaseTimer = t
        }
    }

    /// True while the heartbeat lease timer is armed.
    var isLeaseArmed: Bool { lock.withLock { leaseTimer != nil } }

    /// Pauses everything once no request has arrived for `leaseSeconds`. Driven by the
    /// lease timer; internal so tests can drive it with a manual clock.
    func checkLease() {
        let current = now()
        let expired = lock.withLock { current.timeIntervalSince(lastHeartbeat) > leaseSeconds }
        guard expired else { return }
        pauseAll()
        lock.withLock {
            leaseTimer?.cancel()
            leaseTimer = nil
        }
    }
}
#endif
