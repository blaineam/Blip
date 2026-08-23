import AppIntents

/// Zero-setup Shortcuts / Spotlight phrases for Blip's most useful intents.
struct BlipAppShortcuts: AppShortcutsProvider {

    static let shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetMetricIntent(),
            phrases: [
                "Get a system metric from \(.applicationName)",
                "Check a metric in \(.applicationName)",
                "What's my CPU usage in \(.applicationName)",
            ],
            shortTitle: "Get Metric",
            systemImageName: "gauge.with.dots.needle.50percent"
        )
        AppShortcut(
            intent: RunBenchmarkIntent(),
            phrases: [
                "Run a benchmark in \(.applicationName)",
                "Benchmark my Mac with \(.applicationName)",
                "How fast is my Mac in \(.applicationName)",
            ],
            shortTitle: "Run Benchmark",
            systemImageName: "gauge.with.needle"
        )
        AppShortcut(
            intent: RunDriveSpeedTestIntent(),
            phrases: [
                "Run a drive speed test in \(.applicationName)",
                "Benchmark a disk with \(.applicationName)",
                "Test my drive speed in \(.applicationName)",
            ],
            shortTitle: "Drive Speed Test",
            systemImageName: "internaldrive"
        )
        AppShortcut(
            intent: RunNetworkSpeedTestIntent(),
            phrases: [
                "Run a network speed test in \(.applicationName)",
                "Test my internet speed with \(.applicationName)",
                "Check my connection speed in \(.applicationName)",
            ],
            shortTitle: "Network Speed Test",
            systemImageName: "speedometer"
        )
        AppShortcut(
            intent: RunTracerouteIntent(),
            phrases: [
                "Run a traceroute in \(.applicationName)",
                "Trace a route with \(.applicationName)",
            ],
            shortTitle: "Traceroute",
            systemImageName: "point.topleft.down.curvedto.point.bottomright.up"
        )
        AppShortcut(
            intent: OpenTracerouteWindowIntent(),
            phrases: [
                "Open the traceroute map in \(.applicationName)",
                "Show the \(.applicationName) traceroute map",
            ],
            shortTitle: "Traceroute Map",
            systemImageName: "map"
        )
    }
}
