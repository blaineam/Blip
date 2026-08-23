import AppIntents
import Foundation

// Shortcuts support for Blip on iOS (#feedback: "ios has support for shortcuts too right?").
// Three verbs that make sense from an automation: run a benchmark, kick off a speed test,
// and capture the full stats snapshot as text. Intents resolve live services through the
// environment seam below — same hermetic pattern as the Mac app's intent layer.

@MainActor
enum MobileIntentsEnvironment {
    /// Runs a benchmark through the SHARED engine (published state + history).
    static var benchRunner: (@MainActor (BenchProfile) async -> BenchResult?) = { _ in nil }
    /// Starts a speed test on the shared tester with the user's configured source.
    static var speedStarter: (@MainActor () -> Void) = {}
    /// Produces the current markdown snapshot.
    static var snapshotProvider: (@MainActor () async -> String) = { "" }
    /// Switches the visible tab (for openAppWhenRun intents).
    static var tabSwitcher: (@MainActor (String) -> Void) = { _ in }
}

enum MobileIntentError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)
    var localizedStringResource: LocalizedStringResource {
        switch self { case .failed(let why): return "\(why)" }
    }
}

enum BenchProfileOption: String, AppEnum {
    case quick, full
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Benchmark Profile"
    static let caseDisplayRepresentations: [BenchProfileOption: DisplayRepresentation] = [
        .quick: "Quick (≈6 seconds, no sustained phase)",
        .full: "Full (≈90 seconds, sustained + thermals)",
    ]
    var profile: BenchProfile { self == .quick ? .quick : .full }
}

struct RunBenchmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Benchmark"
    static let description = IntentDescription(
        "Runs Blip Bench — CPU, memory, and GPU against Blip's fixed reference units, comparable with any Mac or iPhone running Blip. Returns the composite score; the detailed result lands in the Bench tab's history.",
        categoryName: "Benchmarks"
    )
    static let openAppWhenRun = true   // benchmarks deserve the foreground: full clock speeds, no background kill

    @Parameter(title: "Profile", default: .quick)
    var profile: BenchProfileOption

    static var parameterSummary: some ParameterSummary {
        Summary("Run a \(\.$profile) benchmark")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        MobileIntentsEnvironment.tabSwitcher("bench")
        guard let result = await MobileIntentsEnvironment.benchRunner(profile.profile) else {
            throw MobileIntentError.failed("The benchmark was cancelled or produced no result.")
        }
        let score = (result.composite * 10).rounded() / 10
        var lines = [
            "Blip Bench: \(Int(result.composite.rounded())) composite",
            "Single-core \(Int(result.singleCore.score.rounded())) · All cores \(Int(result.multiCore.score.rounded())) · Memory \(Int(result.memory.score.rounded()))",
        ]
        if let gpu = result.gpu { lines[1] += " · GPU \(Int(gpu.score.rounded()))" }
        if let lost = result.throttlePercentLost, lost > 0 {
            lines.append("Sustained load loses \(lost)%")
        }
        return .result(value: score, dialog: IntentDialog(stringLiteral: lines.joined(separator: "\n")))
    }
}

struct RunSpeedTestIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Speed Test"
    static let description = IntentDescription(
        "Opens Blip and starts a network speed test using your configured source — the public OpenSpeedTest service or your own server from Settings.",
        categoryName: "Speed Tests"
    )
    static let openAppWhenRun = true   // the public source needs the app's WebKit; results show live

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileIntentsEnvironment.tabSwitcher("speed")
        MobileIntentsEnvironment.speedStarter()
        return .result(dialog: "Speed test started in Blip.")
    }
}

struct GetDeviceSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Device Snapshot"
    static let description = IntentDescription(
        "Returns Blip's full stats snapshot as Markdown text — device, CPU, memory, storage, network — ready to save to a file, append to a note, or send anywhere.",
        categoryName: "Stats"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let md = await MobileIntentsEnvironment.snapshotProvider()
        guard !md.isEmpty else { throw MobileIntentError.failed("Couldn't capture a snapshot.") }
        return .result(value: md)
    }
}

struct BlipMobileShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunBenchmarkIntent(),
            phrases: ["Run a benchmark in \(.applicationName)",
                      "Benchmark my device with \(.applicationName)"],
            shortTitle: "Run Benchmark",
            systemImageName: "gauge.with.needle"
        )
        AppShortcut(
            intent: RunSpeedTestIntent(),
            phrases: ["Run a speed test in \(.applicationName)",
                      "Test my internet speed with \(.applicationName)"],
            shortTitle: "Speed Test",
            systemImageName: "speedometer"
        )
        AppShortcut(
            intent: GetDeviceSnapshotIntent(),
            phrases: ["Get a device snapshot from \(.applicationName)"],
            shortTitle: "Device Snapshot",
            systemImageName: "doc.text"
        )
    }
}
