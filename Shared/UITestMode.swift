import Foundation

// UI-test mode — a DEBUG-only launch argument (`-UITestMode`) that the XCUITest bundles
// (BlipUITests on macOS, BlipMobileUITests on iOS/iPadOS) pass so the app runs
// deterministically: isolated defaults seeded with the screenshot fixtures, no network,
// no helper, no real benchmark/speed-test/ping work (canned results through the real phase
// updates), and animations off.
//
// Release builds compile `isActive` to a constant `false`, so every branch keyed on it is
// dead code the optimizer strips — production behaviour is unchanged. Named options:
//   -UITestScenario empty|seeded     (default seeded: bench/speed history + demo overlays)
//   -UITestBenchOutcome ok|cancel    (cancel: the stub run holds until cancelled)
//   -UITestSpeedOutcome ok|fail      (fail: the stub speed test ends in a failure)
//   -UITestRecommendation            (macOS: seed one suggestion banner)
//   -UITestOpenURL <url>             (iOS: route a deep link at launch)

enum UITestMode {
    #if DEBUG
    static let isActive: Bool = Foundation.ProcessInfo.processInfo.arguments.contains("-UITestMode")

    /// Value following `-<name>` on the command line, if any.
    static func value(_ name: String) -> String? {
        let args = Foundation.ProcessInfo.processInfo.arguments
        guard isActive, let i = args.firstIndex(of: "-" + name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func flag(_ name: String) -> Bool {
        isActive && Foundation.ProcessInfo.processInfo.arguments.contains("-" + name)
    }

    /// Seeded fixtures (history, demo overlays) unless the test asked for an empty start.
    static var isSeeded: Bool { isActive && value("UITestScenario") != "empty" }
    #else
    static let isActive = false
    static func value(_ name: String) -> String? { nil }
    static func flag(_ name: String) -> Bool { false }
    static let isSeeded = false
    #endif

    /// Defaults suite the iOS app uses instead of the real App Group while under UI test.
    static let mobileSuiteName = "com.blainemiller.Blip.uitest"
}
