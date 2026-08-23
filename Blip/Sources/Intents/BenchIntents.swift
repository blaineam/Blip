import AppIntents
import Foundation

// Blip Bench over App Intents — the same surface the other tests expose, which is also what
// makes the feature Soren-verifiable end-to-end: QA drives `quick` (≈6 s, every code path
// including the GPU dispatch) and asserts on the structured result; humans and Shortcuts
// automations run `full` (≈90 s with the sustained/thermal phase).

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
        "Runs Blip Bench — CPU (single and all cores), memory bandwidth and latency, and GPU, scored against Blip's fixed reference units. The full profile adds a sustained phase that measures thermal throttling. Returns the composite score; the detailed result appears in the Bench panel's history.",
        categoryName: "Speed Tests"
    )

    @Parameter(title: "Profile", default: .full)
    var profile: BenchProfileOption

    static var parameterSummary: some ParameterSummary {
        Summary("Run a \(\.$profile) benchmark")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        guard let result = await AppIntentsEnvironment.benchRunner(profile.profile) else {
            throw BlipIntentError.failed("The benchmark was cancelled or produced no result.")
        }
        let score = (result.composite * 10).rounded() / 10
        var lines = [
            "Blip Bench: \(Int(result.composite.rounded())) composite",
            "Single-core \(Int(result.singleCore.score.rounded())) · All cores \(Int(result.multiCore.score.rounded())) · Memory \(Int(result.memory.score.rounded()))",
        ]
        if let gpu = result.gpu { lines[1] += " · GPU \(Int(gpu.score.rounded()))" }
        if let lost = result.throttlePercentLost, lost > 0 {
            lines.append("Sustained load loses \(lost)% (throttle factor \(String(format: "%.2f", result.throttleFactor ?? 1)))")
        }
        return .result(value: score, dialog: IntentDialog(stringLiteral: lines.joined(separator: "\n")))
    }
}
