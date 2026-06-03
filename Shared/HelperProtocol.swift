import Foundation

// MARK: - Constants

enum HelperConstants {
    static let appGroupID = "group.com.blainemiller.Blip"
    static let portFileName = "bliphelper_port"
    static let helperBundleID = "com.blainemiller.BlipHelper"

    /// Returns the App Group container URL, or a fallback in ~/Library/Application Support.
    static var sharedContainerURL: URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return url
        }
        // Fallback for non-sandboxed builds or missing App Group entitlement
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fallback = appSupport.appendingPathComponent("BlipShared")
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Path where the helper writes its TCP port on startup.
    static var portFileURL: URL {
        sharedContainerURL.appendingPathComponent(portFileName)
    }
}

// MARK: - IPC Message Types

struct HelperRequest: Codable, Sendable {
    var type: String // "poll", "kill", "traceroute"
    var token: String // TOTP token

    // Feature A — Kill process (optional for back-compat with old JSON)
    var pid: Int32? = nil // target PID for "kill"
    var force: Bool? = nil // SIGKILL when true, SIGTERM otherwise

    // Feature B — Traceroute / MTR (optional for back-compat)
    var action: String? = nil // "start", "stop", "poll" for "traceroute"
    var host: String? = nil // target host/IP for "traceroute" start
}

struct HelperResponse: Codable, Sendable {
    var type: String // "snapshot", "killResult", "traceroute", or "error"
    var token: String? // TOTP token for response validation
    var data: HelperSnapshot?
    var message: String? // error message / status message

    // Feature A — Kill process result
    var success: Bool? = nil // true if the kill succeeded

    // Feature B — Traceroute / MTR result
    var hops: [HelperTraceHop]? = nil // current per-hop stats
    var running: Bool? = nil // whether a traceroute session is active
}

// MARK: - Traceroute / MTR

/// Per-hop statistics for a continuous (MTR-style) traceroute session.
struct HelperTraceHop: Codable, Sendable {
    var hop: Int
    var host: String
    var sent: Int
    var recv: Int
    var lossPct: Double
    var lastMs: Double?
    var avgMs: Double?
    var bestMs: Double?
    var worstMs: Double?
}

// MARK: - Helper Snapshot (privileged data the sandbox blocks)

struct HelperSnapshot: Codable, Sendable {
    // Fan/thermal data (entire subsystem blocked by sandbox)
    var fans: [HelperFan]
    var cpuTemperature: Double?
    var gpuTemperature: Double?

    // GPU utilization (name/cores available via Metal, but utilization needs IOKit)
    var gpuUtilization: Double

    // Disk I/O speeds (volume space is fine, but IOKit throughput is blocked)
    var diskReadBytesPerSec: UInt64
    var diskWriteBytesPerSec: UInt64
    var diskTotalBytesRead: UInt64
    var diskTotalBytesWritten: UInt64
    var smartStatus: String

    // Per-drive S.M.A.R.T. / health (NVMe health log via IONVMeSMARTUserClient).
    // Optional for IPC resilience if an older helper build is still running.
    var drives: [HelperDriveHealth]?

    // Since-boot network totals from netstat (the sandboxed app can't spawn it).
    var networkTotalDownloaded: UInt64?
    var networkTotalUploaded: UInt64?

    // Battery health details (basic charge/state available, health needs IOKit registry)
    var batteryHealth: Double?
    var batteryCycleCount: Int?
    var batteryCondition: String?
    var batteryTemperature: Double?

    // Process list (proc_* APIs blocked in sandbox)
    var topProcessesByCPU: [HelperProcess]
    var topProcessesByMemory: [HelperProcess]

    // System info (system_profiler subprocess blocked in sandbox)
    var macModelName: String?

    // Helper bundle version (CFBundleShortVersionString) so the app can detect when
    // an installed helper is older than the app and prompt for an update. Optional:
    // nil means a pre-versioning helper, which the app should treat as outdated.
    var helperVersion: String?

    var timestamp: Date
}

/// S.M.A.R.T. / health data for a single physical drive.
/// NVMe fields come from the NVMe SMART/Health Information log (log page 0x02).
struct HelperDriveHealth: Codable, Sendable {
    var name: String          // product name, e.g. "APPLE SSD AP4096Z"
    var bsdName: String       // e.g. "disk0"
    var isInternal: Bool
    var medium: String        // "NVMe", "ATA", etc.
    var smartStatus: String   // "Verified", "Failing", or "" if unknown

    // NVMe SMART/Health log fields (nil when not applicable/available)
    var percentageUsed: Int?          // 0…100+; life remaining ≈ 100 − this
    var availableSpare: Int?          // percent
    var availableSpareThreshold: Int? // percent
    var temperatureCelsius: Int?
    var dataUnitsWritten: UInt64?     // NVMe units; bytes ≈ units × 512000
    var dataUnitsRead: UInt64?
    var powerOnHours: UInt64?
    var powerCycles: UInt64?
    var unsafeShutdowns: UInt64?
    var mediaErrors: UInt64?
    var criticalWarning: Int?         // bitfield; 0 = healthy

    /// Estimated remaining endurance as a percentage (100 = new), or nil if unknown.
    var lifeRemaining: Int? {
        guard let used = percentageUsed else { return nil }
        return max(0, 100 - used)
    }

    /// Bytes written over the drive's lifetime, derived from NVMe data units.
    var bytesWritten: UInt64? {
        guard let u = dataUnitsWritten else { return nil }
        return u &* 512_000
    }

    var bytesRead: UInt64? {
        guard let u = dataUnitsRead else { return nil }
        return u &* 512_000
    }
}

struct HelperFan: Codable, Sendable {
    var id: Int
    var name: String
    var currentRPM: Int
    var minRPM: Int
    var maxRPM: Int
}

struct HelperProcess: Codable, Sendable {
    var pid: Int32
    var name: String
    var cpu: Double
    var memory: UInt64
    /// PNG-encoded app icon (16x16), nil for system processes without a bundle.
    var icon: Data?
}

// MARK: - TCP Framing

/// Length-prefixed message framing for TCP.
/// Format: [4-byte big-endian length][JSON payload]
enum MessageFraming {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    /// Extract length from a 4-byte header.
    static func decodeLength(from header: Data) -> UInt32? {
        guard header.count >= 4 else { return nil }
        return header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}
