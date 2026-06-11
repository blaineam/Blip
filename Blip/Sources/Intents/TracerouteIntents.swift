import AppIntents
import Foundation

// MARK: - Parameter validation + summary (pure, unit-tested)

enum TracerouteParameters {
    static let minDuration = 3
    static let maxDuration = 120
    static let defaultDuration = 10

    /// Clamps the sampling window to something sane (3–120 s).
    static func clampedDuration(_ seconds: Int) -> Int {
        min(max(seconds, minDuration), maxDuration)
    }

    /// Resolves the target host: explicit parameter → Settings target → ping
    /// target → 1.1.1.1, trimming whitespace at each step.
    static func resolveHost(parameter: String?, settingsTarget: String?, pingTarget: String?) -> String {
        for candidate in [parameter, settingsTarget, pingTarget] {
            if let c = candidate?.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        }
        return "1.1.1.1"
    }
}

enum TracerouteSummary {
    /// One-line MTR digest: hop count, end-to-end latency, worst loss.
    static func make(hops: [HelperTraceHop], host: String) -> String {
        guard !hops.isEmpty else {
            return "Traceroute to \(host): no replies yet."
        }
        var s = "Traceroute to \(host): \(hops.count) hops"
        if let last = hops.last, let avg = last.avgMs {
            s += String(format: ", final hop %@ avg %.1f ms", last.host, avg)
        }
        let lossy = hops.filter { $0.lossPct > 0 && $0.sent > 0 }
        if let worst = lossy.max(by: { $0.lossPct < $1.lossPct }) {
            s += String(format: ", worst loss %.0f%% at hop %d (%@)", worst.lossPct, worst.hop, worst.host)
        } else {
            s += ", no packet loss"
        }
        return s
    }
}

// MARK: - Run Traceroute

struct RunTracerouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Traceroute"
    static let description = IntentDescription(
        "Runs Blip's continuous traceroute (MTR) against a host, samples it for the given number of seconds, and returns a per-route summary — hop count, final-hop latency, and worst packet loss. Optionally keeps the session running afterwards so the Network panel and Traceroute Map pick it up live.",
        categoryName: "Network"
    )

    @Parameter(title: "Host", description: "Hostname or IP address. Leave empty to use the target from Settings → Network.")
    var host: String?

    @Parameter(title: "Sample For (seconds)", description: "How long to sample the route (3–120 seconds).", default: 10, inclusiveRange: (3, 120))
    var duration: Int

    @Parameter(title: "Keep Running", description: "Leave the MTR session running after the summary (stop it with Stop Traceroute or from the Network panel).", default: false)
    var keepRunning: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Trace route to \(\.$host) for \(\.$duration) seconds") {
            \.$keepRunning
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let control = AppIntentsEnvironment.tracerouteControl else { throw BlipIntentError.appNotReady }

        let defaults = AppIntentsEnvironment.defaults
        let target = TracerouteParameters.resolveHost(
            parameter: host,
            settingsTarget: defaults.string(forKey: "tracerouteTarget"),
            pingTarget: defaults.string(forKey: "pingTarget")
        )
        guard HostValidation.isValid(target) else { throw BlipIntentError.invalidHost(target) }

        let seconds = TracerouteParameters.clampedDuration(duration)

        await control.start(target)
        try await Task.sleep(for: .seconds(seconds))
        let (hops, _) = await control.poll()
        if !keepRunning {
            await control.stop()
        }

        let summary = TracerouteSummary.make(hops: hops, host: target)
        return .result(value: summary, dialog: "\(summary)")
    }
}

// MARK: - Stop Traceroute

struct StopTracerouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Traceroute"
    static let description = IntentDescription(
        "Stops Blip's running traceroute (MTR) session, if any.",
        categoryName: "Network"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let control = AppIntentsEnvironment.tracerouteControl else { throw BlipIntentError.appNotReady }
        await control.stop()
        return .result(dialog: "Traceroute stopped.")
    }
}

// MARK: - Open Traceroute Window

struct OpenTracerouteWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Traceroute Map"
    static let description = IntentDescription(
        "Opens Blip's Traceroute Map window, optionally pre-targeting a host.",
        categoryName: "Network"
    )

    static let openAppWhenRun = true

    @Parameter(title: "Host", description: "Optional hostname or IP to pre-target.")
    var host: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Open the Traceroute Map for \(\.$host)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let open = AppIntentsEnvironment.openTracerouteWindow else { throw BlipIntentError.appNotReady }
        var target: String?
        if let h = host?.trimmingCharacters(in: .whitespaces), !h.isEmpty {
            guard HostValidation.isValid(h) else { throw BlipIntentError.invalidHost(h) }
            target = h
        }
        open(target)
        return .result()
    }
}
