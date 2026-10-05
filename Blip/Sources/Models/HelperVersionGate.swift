import Foundation

enum KeepAwakeHelperState { case ready, outdated, absent }

/// Version rules for the App Store build's Blip Helper, kept free of UI and of the live
/// HelperClient so they can be checked in every build configuration. Versions compare
/// numerically ("2.0.10" is newer than "2.0.5").
enum HelperVersionGate {
    /// First helper release that serves the `keepAwake` request.
    static let keepAwakeMinimum = "2.0.5"

    /// Whether the closed-lid / jiggle extras can be offered through a helper.
    static func keepAwakeState(connected: Bool, helperVersion: String?) -> KeepAwakeHelperState {
        guard connected else { return .absent }
        guard let version = helperVersion, !version.isEmpty,
              version.compare(keepAwakeMinimum, options: .numeric) != .orderedAscending else {
            return .outdated
        }
        return .ready
    }

    /// The connected helper is outdated if it reports no version (a pre-versioning
    /// build) or a version older than the app. A disconnected helper is never "outdated".
    static func isOutdated(installed: String?, app: String, connected: Bool) -> Bool {
        guard connected else { return false }
        guard let installed, !installed.isEmpty else { return true }
        return installed.compare(app, options: .numeric) == .orderedAscending
    }
}
