import SwiftUI

// DEBUG-only plumbing for `-UITestMode` (see Shared/UITestMode.swift). Everything that
// changes behaviour lives under #if DEBUG; in Release the view modifier below is an identity.

extension View {
    /// Under UI test, implicit and explicit SwiftUI animations are switched off so XCUITest
    /// sees settled state immediately (and repeat-forever pulses never keep the app busy).
    @ViewBuilder
    func uiTestAnimationsOff() -> some View {
        #if DEBUG
        if UITestMode.isActive {
            self.transaction { $0.disablesAnimations = true; $0.animation = nil }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
enum MobileUITestSupport {
    /// UserDefaults.standard keys the app reads — reset so every UI-test launch starts clean
    /// whatever the simulator ran before (the screenshot rig's demo flags included).
    private static let standardKeys = [
        "mobile.speed.source", "mobile.speed.server", "mobile.ping.target", "mobile.trace.target",
        "blip.demoSeed", "blip.route", "blip.demoNetworkMode",
    ]

    static func prepareIfActive() {
        guard UITestMode.isActive else { return }
        // The isolated suite (never the real App Group) starts empty on every launch.
        UserDefaults.standard.removePersistentDomain(forName: UITestMode.mobileSuiteName)
        UserDefaults(suiteName: UITestMode.mobileSuiteName)?.removePersistentDomain(forName: UITestMode.mobileSuiteName)
        for key in standardKeys { UserDefaults.standard.removeObject(forKey: key) }
        UIView.setAnimationsEnabled(false)
    }
}
#endif
