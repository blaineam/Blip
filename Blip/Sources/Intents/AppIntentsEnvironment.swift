import Foundation

// MARK: - App Intents dependency seams
//
// Intents resolve every live dependency (monitor snapshot, speed testers,
// traceroute control, UserDefaults) through this environment. The AppDelegate
// installs the real services at launch; unit tests install mocks, keeping the
// intent layer hermetic — no IOKit, subprocesses, or network in tests.

/// Read access to the live monitoring data App Intents need.
@MainActor
protocol MetricSource: AnyObject {
    var metricSnapshot: SystemSnapshot { get }
    /// 60×2s in-memory history (oldest-first) for charted metrics, else nil.
    func metricHistory(_ id: MetricID) -> [Double]?
    /// Waits briefly for the first poll after a cold (Shortcut-triggered) launch.
    func ensureFreshSample() async
}

extension SystemMonitor: MetricSource {
    var metricSnapshot: SystemSnapshot { snapshot }

    func metricHistory(_ id: MetricID) -> [Double]? {
        switch id {
        case .cpuUsage: return cpuHistory.values
        case .memoryUsage: return memoryHistory.values
        case .gpuUsage: return gpuHistory.values
        case .diskRead: return diskReadHistory.values
        case .diskWrite: return diskWriteHistory.values
        case .netDown: return netDownHistory.values
        case .netUp: return netUpHistory.values
        default: return nil
        }
    }
}

/// Start/stop/poll handles for the continuous traceroute (MTR) session.
/// Main-actor closures: they capture the @MainActor SystemMonitor.
struct TracerouteControl {
    var start: @MainActor (String) async -> Void
    var stop: @MainActor () async -> Void
    var poll: @MainActor () async -> (hops: [HelperTraceHop], running: Bool)
}

@MainActor
enum AppIntentsEnvironment {
    /// Live monitor; installed by AppDelegate at launch, mocked in tests.
    static var metricSource: (any MetricSource)?

    /// Mounted-volume inventory for the VolumeEntity query.
    static var volumesProvider: @MainActor () -> [VolumeInfo] = { DiskMonitor.readVolumes() }

    /// Defaults store for Get/Set Setting (tests use a scratch suite).
    static var defaults: UserDefaults = .standard

    /// Traceroute session control; installed by AppDelegate.
    static var tracerouteControl: TracerouteControl?

    /// Opens the Traceroute Map window (optionally pre-targeting a host).
    static var openTracerouteWindow: (@MainActor (String?) -> Void)?

    /// Runs one network speed test to completion. Installed by AppDelegate so
    /// results land in the shared SpeedTester's history (panel stays in sync).
    static var networkSpeedRunner: (@MainActor (SpeedTestServer) async throws -> NetSpeedResult)?

    /// Runs one disk benchmark against a mount point. Defaults to the pure
    /// runner; AppDelegate wraps it to also record into the DiskSpeedTester.
    static var diskSpeedRunner: @MainActor (DiskBenchmark.Size, String) async throws -> DiskSpeedResult = { size, mountPoint in
        try await IntentDiskSpeedRunner.run(size: size, mountPoint: mountPoint)
    }
}

// MARK: - Intent-facing disk benchmark runner

enum IntentDiskSpeedRunner {
    struct AccessError: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    /// Runs the uncached sequential benchmark on `mountPoint` off the main
    /// thread. "/" benchmarks the app's temp directory (boot volume); other
    /// volumes get a direct path in the unsandboxed build. The sandboxed App
    /// Store build can only reach an external volume through the user-granted
    /// security-scoped bookmark saved by the Disk panel.
    static func run(size: DiskBenchmark.Size, mountPoint: String) async throws -> DiskSpeedResult {
        var directory: URL?
        var scopedURL: URL?

        if mountPoint != "/" {
            #if APPSTORE
            guard let bookmark = UserDefaults.standard.data(forKey: "diskSpeedTestBookmark") else {
                throw AccessError(message: "Blip can't write to \(mountPoint) under the App Store sandbox. Open the Disk panel and run that volume's speed test once to grant access, then this shortcut will work.")
            }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.path == mountPoint || url.path.hasPrefix(mountPoint + "/") else {
                throw AccessError(message: "Blip's saved disk-test location isn't on \(mountPoint). Open the Disk panel and run that volume's speed test once to grant access.")
            }
            if url.startAccessingSecurityScopedResource() { scopedURL = url }
            directory = url
            #else
            directory = URL(fileURLWithPath: mountPoint, isDirectory: true)
            #endif
        }

        defer { scopedURL?.stopAccessingSecurityScopedResource() }

        let dir = directory
        return try await Task.detached(priority: .utility) {
            try DiskBenchmark.run(size: size, directory: dir,
                                  progress: { _, _ in },
                                  isCancelled: { Task.isCancelled })
        }.value
    }
}
