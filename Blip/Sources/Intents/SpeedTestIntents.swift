import AppIntents
import Foundation

// MARK: - Volume Entity

/// A mounted volume, exposed to Shortcuts so "Run Drive Speed Test" can target
/// any drive — wired to the same per-volume benchmark the Disk panel uses.
struct VolumeEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Volume")
    static let defaultQuery = VolumeEntityQuery()

    /// Mount point path (matches VolumeInfo.id).
    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Total Capacity (bytes)")
    var totalBytes: Double

    @Property(title: "Free Space (bytes)")
    var freeBytes: Double

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(MetricFormatter.format(freeBytes, unit: .bytes)) free of \(MetricFormatter.format(totalBytes, unit: .bytes))",
            image: .init(systemName: id == "/" ? "internaldrive" : "externaldrive")
        )
    }

    init(volume: VolumeInfo) {
        self.id = volume.mountPoint
        self.name = volume.name
        self.totalBytes = Double(volume.totalBytes)
        self.freeBytes = Double(volume.freeBytes)
    }
}

struct VolumeEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [VolumeEntity] {
        let volumes = AppIntentsEnvironment.volumesProvider()
        return identifiers.compactMap { id in
            volumes.first { $0.mountPoint == id }.map(VolumeEntity.init)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [VolumeEntity] {
        AppIntentsEnvironment.volumesProvider().map(VolumeEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [VolumeEntity] {
        AppIntentsEnvironment.volumesProvider()
            .filter { $0.name.localizedCaseInsensitiveContains(string) || $0.mountPoint.localizedCaseInsensitiveContains(string) }
            .map(VolumeEntity.init)
    }

    @MainActor
    func defaultResult() async -> VolumeEntity? {
        AppIntentsEnvironment.volumesProvider().first { $0.mountPoint == "/" }.map(VolumeEntity.init)
    }
}

// MARK: - Benchmark size

enum DiskBenchmarkSizeOption: String, AppEnum {
    case small
    case medium
    case large

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Test Size"
    static let caseDisplayRepresentations: [DiskBenchmarkSizeOption: DisplayRepresentation] = [
        .small: "128 MB",
        .medium: "512 MB",
        .large: "1 GB",
    ]

    var benchmarkSize: DiskBenchmark.Size {
        switch self {
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        }
    }
}

// MARK: - Result summaries (pure, unit-tested)

enum SpeedTestSummary {
    static func disk(_ r: DiskSpeedResult, volumeName: String, sizeLabel: String) -> String {
        var s = String(format: "%@ (%@): write %.0f MB/s, read %.0f MB/s", volumeName, sizeLabel, r.writeMBps, r.readMBps)
        if let iops = r.randomReadIOPS {
            s += String(format: ", %.0f random-read IOPS", iops)
        }
        return s
    }

    static func network(_ r: NetSpeedResult, serverName: String) -> String {
        var s = String(format: "%@: down %.1f Mbps", serverName, r.downMbps)
        if let up = r.upMbps {
            s += String(format: ", up %.1f Mbps", up)
        }
        return s
    }
}

// MARK: - Run Drive Speed Test

struct RunDriveSpeedTestIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Drive Speed Test"
    static let description = IntentDescription(
        "Benchmarks a mounted volume with Blip's uncached sequential write/read test (plus random-read IOPS) and returns the result. The result also appears in the Disk panel's history.",
        categoryName: "Speed Tests"
    )

    @Parameter(title: "Volume")
    var volume: VolumeEntity

    @Parameter(title: "Test Size", default: .medium)
    var size: DiskBenchmarkSizeOption

    static var parameterSummary: some ParameterSummary {
        Summary("Run a \(\.$size) speed test on \(\.$volume)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Re-validate against the live volume set — the entity may be stale.
        let volumes = AppIntentsEnvironment.volumesProvider()
        guard let live = volumes.first(where: { $0.mountPoint == volume.id }) else {
            throw BlipIntentError.volumeNotMounted(volume.name)
        }

        let result: DiskSpeedResult
        do {
            result = try await AppIntentsEnvironment.diskSpeedRunner(size.benchmarkSize, live.mountPoint)
        } catch let error as IntentDiskSpeedRunner.AccessError {
            throw BlipIntentError.failed(error.message)
        } catch is DiskBenchmark.CancelledError {
            throw BlipIntentError.failed("The disk speed test was cancelled.")
        } catch let error as SpeedTestRunFailure {
            throw BlipIntentError.busy(error.message)
        } catch {
            throw BlipIntentError.failed((error as NSError).localizedDescription)
        }

        let sizeLabel = size.benchmarkSize.label
        let summary = SpeedTestSummary.disk(result, volumeName: live.name, sizeLabel: sizeLabel)
        return .result(value: summary, dialog: "\(summary)")
    }
}

// MARK: - Network provider choice

enum NetworkSpeedProvider: String, AppEnum {
    /// Follow the server selected in Blip's Speed Test panel.
    case appSetting
    case publicOpenSpeedTest
    case selfHosted

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Server"
    static let caseDisplayRepresentations: [NetworkSpeedProvider: DisplayRepresentation] = [
        .appSetting: "App Setting",
        .publicOpenSpeedTest: "OpenSpeedTest (public)",
        .selfHosted: "Self-hosted server",
    ]
}

/// Pure resolution of the provider choice + stored settings into a server.
/// Mirrors the Speed Test panel: "public" unless the user picked self-hosted.
enum NetworkSpeedProviderResolver {
    enum Resolution: Equatable {
        case server(SpeedTestServer)
        case missingURL
    }

    static func resolve(choice: NetworkSpeedProvider, storedKind: String?, storedURL: String?) -> Resolution {
        switch choice {
        case .publicOpenSpeedTest:
            return .server(.openSpeedTestPublic)
        case .selfHosted:
            let server = SpeedTestServer.openSpeedTest(baseURL: storedURL ?? "")
            return server.openSpeedTestBase == nil ? .missingURL : .server(server)
        case .appSetting:
            if storedKind == "selfhosted" {
                let server = SpeedTestServer.openSpeedTest(baseURL: storedURL ?? "")
                return server.openSpeedTestBase == nil ? .missingURL : .server(server)
            }
            return .server(.openSpeedTestPublic)
        }
    }
}

// MARK: - Run Network Speed Test

struct RunNetworkSpeedTestIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Network Speed Test"
    static let description = IntentDescription(
        "Runs Blip's network speed test — against OpenSpeedTest's public test or your self-hosted OpenSpeedTest server (set its address in Settings → Network) — and returns the measured throughput. The result also appears in the Network panel's history.",
        categoryName: "Speed Tests"
    )

    @Parameter(title: "Server", default: .appSetting)
    var provider: NetworkSpeedProvider

    static var parameterSummary: some ParameterSummary {
        Summary("Run a network speed test using \(\.$provider)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let runner = AppIntentsEnvironment.networkSpeedRunner else { throw BlipIntentError.appNotReady }

        let defaults = AppIntentsEnvironment.defaults
        let resolution = NetworkSpeedProviderResolver.resolve(
            choice: provider,
            storedKind: defaults.string(forKey: "speedTestServerKind"),
            storedURL: defaults.string(forKey: "speedTestOpenSpeedTestURL")
        )

        guard case let .server(server) = resolution else {
            throw BlipIntentError.failed("No self-hosted OpenSpeedTest server is configured. Set its address in Blip's Settings → Network.")
        }

        let result: NetSpeedResult
        do {
            result = try await runner(server)
        } catch let error as SpeedTestRunFailure {
            throw BlipIntentError.failed(error.message)
        } catch {
            throw BlipIntentError.failed((error as NSError).localizedDescription)
        }

        let summary = SpeedTestSummary.network(result, serverName: server.displayName)
        return .result(value: summary, dialog: "\(summary)")
    }
}
