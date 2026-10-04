import Foundation
import IOKit.pwr_mgt

// MARK: - Keep Awake
//
// Stops the Mac from idle-sleeping for a while or until turned off. The base
// feature is a plain IOKit power assertion, which works in every build,
// sandbox included. The two extras — staying awake with the lid closed and
// jiggling the mouse — run in-process in the direct download and through
// Blip Helper in the App Store build (see Shared/KeepAwake).

enum KeepAwakeDuration: String, CaseIterable, Sendable {
    case thirtyMinutes, oneHour, twoHours, fourHours, indefinitely

    /// nil = until turned off.
    var interval: TimeInterval? {
        switch self {
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .indefinitely: return nil
        }
    }

    var title: String {
        switch self {
        case .thirtyMinutes: return String(localized: "30 Minutes")
        case .oneHour: return String(localized: "1 Hour")
        case .twoHours: return String(localized: "2 Hours")
        case .fourHours: return String(localized: "4 Hours")
        case .indefinitely: return String(localized: "Until Turned Off")
        }
    }

    /// Chip label in the Keep Awake panel.
    var shortTitle: String {
        switch self {
        case .thirtyMinutes: return String(localized: "30 min")
        case .oneHour: return String(localized: "1 hr")
        case .twoHours: return String(localized: "2 hr")
        case .fourHours: return String(localized: "4 hr")
        case .indefinitely: return "∞"
        }
    }
}

/// Seam over IOPMAssertionCreateWithName so tests don't hold real assertions.
@MainActor
protocol PowerAssertionBackend: AnyObject {
    func create(keepDisplayOn: Bool, reason: String) -> UInt32?
    func release(_ id: UInt32)
}

@MainActor
final class IOKitPowerAssertions: PowerAssertionBackend {
    func create(keepDisplayOn: Bool, reason: String) -> UInt32? {
        // Display-sleep prevention implies system-sleep prevention.
        let type = keepDisplayOn ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}

/// Where the closed-lid and jiggle extras run. nil status = unavailable.
@MainActor
protocol KeepAwakeExtrasBackend: AnyObject {
    func apply(_ request: KeepAwakeExtrasRequest) async -> KeepAwakeExtrasStatus?
}

#if APPSTORE
/// The App Store build hands the extras to Blip Helper.
@MainActor
final class HelperKeepAwakeExtras: KeepAwakeExtrasBackend {
    private let client: HelperClient
    init(client: HelperClient) { self.client = client }

    func apply(_ request: KeepAwakeExtrasRequest) async -> KeepAwakeExtrasStatus? {
        guard client.isConnected else { return nil }
        return await client.keepAwake(request)
    }
}
#else
/// The direct download runs the extras itself.
@MainActor
final class LocalKeepAwakeExtras: KeepAwakeExtrasBackend {
    nonisolated static let host = KeepAwakeExtrasHost(ownerName: "Blip")

    func apply(_ request: KeepAwakeExtrasRequest) async -> KeepAwakeExtrasStatus? {
        await Task.detached(priority: .userInitiated) { Self.host.apply(request) }.value
    }
}
#endif

@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    enum Keys {
        static let keepDisplayOn = "keepAwakeDisplay"
        static let lidClosed = "keepAwakeLidClosed"
        static let jiggle = "keepAwakeJiggle"
        static let lastDuration = "keepAwakeLastDuration"
        static let menuBarIndicator = "keepAwakeMenuBarIndicator"
    }

    /// Lid-closed mode stops itself on battery at or below this level.
    static let lowBatteryPercent: Double = 10

    @Published private(set) var isActive = false
    /// When Keep Awake ends; nil while active means "until turned off".
    @Published private(set) var endsAt: Date?
    @Published private(set) var extras = KeepAwakeExtrasStatus()
    /// Last thing worth telling the user (prompt cancelled, battery low…).
    @Published private(set) var notice: String?

    var assertions: any PowerAssertionBackend = IOKitPowerAssertions()
    var extrasBackend: (any KeepAwakeExtrasBackend)?
    var defaults: UserDefaults = .standard
    var now: () -> Date = Date.init

    private var assertionID: UInt32?
    private var assertionKeepsDisplayOn = false
    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var lastSentExtras: KeepAwakeExtrasRequest?
    private var batteryLow = false

    init() {
        #if !APPSTORE
        extrasBackend = LocalKeepAwakeExtras()
        #endif
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    var keepDisplayOn: Bool { defaults.object(forKey: Keys.keepDisplayOn) as? Bool ?? true }
    var wantsLidClosed: Bool { defaults.bool(forKey: Keys.lidClosed) }
    var wantsJiggle: Bool { defaults.bool(forKey: Keys.jiggle) }

    // MARK: Control

    /// The duration the switch uses — whatever was picked last.
    var lastDuration: KeepAwakeDuration {
        defaults.string(forKey: Keys.lastDuration).flatMap(KeepAwakeDuration.init(rawValue:)) ?? .indefinitely
    }

    /// The row's switch: off → on for the last-picked duration, on → off.
    func toggle() {
        if isActive { stop() } else { start(lastDuration) }
    }

    func start(_ duration: KeepAwakeDuration) {
        defaults.set(duration.rawValue, forKey: Keys.lastDuration)
        endsAt = duration.interval.map { now().addingTimeInterval($0) }
        notice = nil
        isActive = true
        applyAssertion()
        startTimer()
        pushExtras(force: true)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        endsAt = nil
        if let id = assertionID { assertions.release(id) }
        assertionID = nil
        timer?.invalidate()
        timer = nil
        pushExtras(force: true)
    }

    /// Ends Keep Awake once its time is up and refreshes the extras heartbeat.
    func tick() {
        guard isActive else { return }
        if let endsAt, now() >= endsAt {
            stop()
            return
        }
        pushExtras(force: true)
    }

    /// Fed from the monitor's snapshot: pauses lid-closed mode on low battery
    /// so a Mac asleep-looking in a bag can't run itself flat (and hot).
    func updateBattery(isPresent: Bool, onBattery: Bool, level: Double) {
        let low = isPresent && onBattery && level <= Self.lowBatteryPercent
        guard low != batteryLow else { return }
        batteryLow = low
        if low && isActive && wantsLidClosed {
            notice = String(localized: "Battery low — the Mac can sleep with the lid closed again.")
        }
        pushExtras(force: false)
    }

    /// Opens the Accessibility prompt for whichever process jiggles.
    func requestJigglePermission() {
        let request = KeepAwakeExtrasRequest(lidClosed: effectiveLidClosed, jiggle: isActive && wantsJiggle,
                                             requestJigglePermission: true)
        send(request)
    }

    /// Re-reads the extras state (e.g. whether jiggle permission was granted)
    /// for Settings, without changing anything.
    func refreshExtras() {
        send(KeepAwakeExtrasRequest(lidClosed: effectiveLidClosed, jiggle: isActive && wantsJiggle))
    }

    // MARK: Internals

    private var effectiveLidClosed: Bool { isActive && wantsLidClosed && !batteryLow }

    private func settingsChanged() {
        guard isActive else { return }
        if keepDisplayOn != assertionKeepsDisplayOn { applyAssertion() }
        pushExtras(force: false)
    }

    private func applyAssertion() {
        let display = keepDisplayOn
        if assertionID != nil && display == assertionKeepsDisplayOn { return }
        // Create the new assertion before releasing the old one so there's no gap.
        let newID = assertions.create(keepDisplayOn: display, reason: "Blip Keep Awake")
        if let old = assertionID { assertions.release(old) }
        assertionID = newID
        assertionKeepsDisplayOn = display
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Sends the wanted extras state when it changed, or on every tick while
    /// any extra is on (the helper treats requests as a heartbeat).
    private func pushExtras(force: Bool) {
        let request = KeepAwakeExtrasRequest(lidClosed: effectiveLidClosed, jiggle: isActive && wantsJiggle)
        let idle = !request.lidClosed && !request.jiggle
        if request == lastSentExtras && (!force || idle) { return }
        if lastSentExtras == nil && idle { return }  // nothing was ever on
        send(request)
    }

    private func send(_ request: KeepAwakeExtrasRequest) {
        lastSentExtras = request
        guard let backend = extrasBackend else { return }
        Task { [weak self] in
            let status = await backend.apply(request)
            self?.received(status, for: request)
        }
    }

    private func received(_ status: KeepAwakeExtrasStatus?, for request: KeepAwakeExtrasRequest) {
        guard let status else {
            extras = KeepAwakeExtrasStatus()
            return
        }
        extras = status
        if let error = status.lidError, request.lidClosed {
            // Revert the switch like Launch at Login does, so it doesn't re-prompt.
            defaults.set(false, forKey: Keys.lidClosed)
            notice = error == "cancelled"
                ? String(localized: "Lid-closed mode needs your administrator password.")
                : String(localized: "Couldn't keep the Mac awake with the lid closed.")
        }
        if status.lidPending {
            // Poll until the password prompt is answered.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isActive else { return }
                self.send(KeepAwakeExtrasRequest(lidClosed: self.effectiveLidClosed,
                                                 jiggle: self.isActive && self.wantsJiggle))
            }
        }
    }
}
