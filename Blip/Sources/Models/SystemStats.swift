import Foundation
import AppKit

// MARK: - CPU

struct CPUStats: Sendable {
    var totalUsage: Double = 0
    var userUsage: Double = 0
    var systemUsage: Double = 0
    var coreUsages: [Double] = []
    var loadAverage1: Double = 0
    var loadAverage5: Double = 0
    var loadAverage15: Double = 0
    var physicalCores: Int = 0
    var logicalCores: Int = 0
    var performanceCores: Int = 0
    var efficiencyCores: Int = 0
}

// MARK: - Memory

struct MemoryStats: Sendable {
    var total: UInt64 = 0
    var used: UInt64 = 0       // App Memory + Wired + Compressed (matches Activity Monitor "Memory Used")
    var free: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var appMemory: UInt64 = 0  // Active + Inactive - Purgeable (matches Activity Monitor "App Memory")
    var cachedFiles: UInt64 = 0 // Purgeable + External pages (matches Activity Monitor "Cached Files")
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressureLevel: Int = 0 // 0=nominal, 1=warning, 2=critical, 4=urgent (from kernel)

    var usagePercent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }

    /// Memory pressure as percentage for the pressure bar
    var pressurePercent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }
}

// MARK: - Disk

struct DiskStats: Sendable {
    var volumes: [VolumeInfo] = []
    var readBytesPerSec: UInt64 = 0
    var writeBytesPerSec: UInt64 = 0
    var totalBytesRead: UInt64 = 0
    var totalBytesWritten: UInt64 = 0
    var smartStatus: String = ""
    var drives: [DriveHealth] = []

    var primaryUsagePercent: Double {
        guard let primary = volumes.first else { return 0 }
        return primary.usagePercent
    }
}

/// S.M.A.R.T. / health for a physical drive (sourced from the helper's NVMe health log).
struct DriveHealth: Identifiable, Sendable {
    var id: String { bsdName.isEmpty ? name : bsdName }
    let name: String
    let bsdName: String
    let isInternal: Bool
    let medium: String
    let smartStatus: String
    let percentageUsed: Int?
    let availableSpare: Int?
    let availableSpareThreshold: Int?
    let temperatureCelsius: Int?
    let bytesWritten: UInt64?
    let bytesRead: UInt64?
    let powerOnHours: UInt64?
    let powerCycles: UInt64?
    let unsafeShutdowns: UInt64?
    let mediaErrors: UInt64?
    let criticalWarning: Int?

    /// Estimated remaining endurance (100 = new), or nil if unknown.
    var lifeRemaining: Int? {
        guard let used = percentageUsed else { return nil }
        return max(0, 100 - used)
    }

    var isHealthy: Bool { (criticalWarning ?? 0) == 0 }
}

struct VolumeInfo: Identifiable, Sendable {
    var id: String { mountPoint }
    let name: String
    let mountPoint: String
    let totalBytes: UInt64
    let freeBytes: UInt64

    var usedBytes: UInt64 { totalBytes - freeBytes }
    var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

/// Result of a sequential disk speed benchmark. Speeds are in MB/s (1 MB = 1_000_000 bytes).
struct DiskSpeedResult: Sendable {
    let writeMBps: Double
    let readMBps: Double
    let randomReadIOPS: Double?
    let timestamp: Date
}

// MARK: - GPU

struct GPUStats: Sendable {
    var name: String = "Apple GPU"
    var utilization: Double = 0
    var temperature: Double = 0
    var coreCount: Int = 0
}

// MARK: - Network

struct InterfaceInfo: Identifiable, Sendable {
    let id: String // interface name e.g. "en0"
    let name: String // display name e.g. "Wi-Fi" or "Ethernet"
    let ipv4: String
    let ipv6: String
    let macAddress: String
    let isActive: Bool
}

struct NetworkStats: Sendable {
    var isConnected: Bool = false
    var interfaceName: String = ""
    var uploadSpeed: UInt64 = 0
    var downloadSpeed: UInt64 = 0
    var ipv4Address: String = "—"
    var ipv6Address: String = "—"
    var lanAddress: String = "—"
    var wanAddress: String = "—"
    var vpnAddress: String = "—"
    var vpnInterface: String = ""
    var isVPNActive: Bool = false
    var pingMs: Double? = nil
    var routerPingMs: Double? = nil
    var routerIP: String = "—"
    var macAddress: String = "—"
    var totalBytesDownloaded: UInt64 = 0
    var totalBytesUploaded: UInt64 = 0
    var interfaces: [InterfaceInfo] = []
    /// Network is metered/expensive (e.g. cellular or a personal hotspot).
    var isExpensive: Bool = false
    /// Network is in Low Data Mode / otherwise constrained.
    var isConstrained: Bool = false
}

// MARK: - Battery

struct BatteryStats: Sendable {
    var level: Double = 0
    var isCharging: Bool = false
    var cycleCount: Int = 0
    var health: Double = 100
    var condition: String = "Normal"
    var temperature: Double = 0
    var timeRemaining: Int = -1
    var powerSource: String = "Battery"
    var isPresent: Bool = false
}

// MARK: - Fan

struct FanStats: Sendable {
    var fans: [FanInfo] = []
    var cpuTemperature: Double? = nil
    var gpuTemperature: Double? = nil
}

struct FanInfo: Identifiable, Sendable {
    let id: Int
    let name: String
    var currentRPM: Int = 0
    var minRPM: Int = 0
    var maxRPM: Int = 0
}

// MARK: - Process

struct ProcessInfo: Identifiable, Sendable {
    let id: pid_t
    let name: String
    let cpu: Double
    let memory: UInt64
    let icon: Data?
    /// True when owned by the logged-in user (a user-space process). System/root
    /// processes are false. Defaults true for sources that can't determine ownership.
    var isUserOwned: Bool = true
}

// MARK: - Aggregate

// MARK: - System Info

struct SystemInfo: Sendable {
    var uptime: TimeInterval = 0
    var thermalLevel: ThermalLevel = .nominal
    var blipMemoryMB: Double = 0
    var blipCPU: Double = 0
    var macModel: String = ""
    var macOSVersion: String = ""
}

enum ThermalLevel: String, Sendable {
    case nominal = "Nominal"
    case fair = "Fair"
    case serious = "Serious"
    case critical = "Critical"
}

// MARK: - Optimization Recommendations

/// A dismissable suggestion to improve the Mac's performance, health, or longevity.
struct Recommendation: Identifiable, Sendable, Equatable {
    enum Severity: Int, Sendable { case info = 0, warning = 1, critical = 2 }
    let id: String        // stable across polls so dismissal sticks
    let severity: Severity
    let icon: String      // SF Symbol
    let title: String
    let detail: String
}

/// Pure rules engine that turns a snapshot into actionable recommendations. Each rule
/// has a stable id so the UI can remember dismissals.
enum RecommendationsEngine {
    static func analyze(_ s: SystemSnapshot) -> [Recommendation] {
        var recs: [Recommendation] = []

        // Runaway CPU process — only ever suggest quitting a user-space application,
        // never a system service / agent (WindowServer, kernel_task, mds, Dock, Finder…).
        if let p = s.topProcessesByCPU.first(where: {
            $0.cpu > 85 && $0.isUserOwned && !isSystemProcess($0.name)
        }) {
            recs.append(.init(id: "cpu-hog", severity: .warning, icon: "cpu",
                title: "\(p.name) is using \(Int(p.cpu))% CPU",
                detail: "Quitting or restarting it would cut heat, fan noise, and battery drain."))
        }

        // Memory pressure / swap
        if s.memory.pressureLevel >= 2 {
            recs.append(.init(id: "mem-pressure", severity: .critical, icon: "memorychip",
                title: "Memory pressure is high",
                detail: "Close some apps or browser tabs — heavy swapping wears the SSD and slows things down."))
        } else if s.memory.swapUsed > 3_000_000_000 {
            recs.append(.init(id: "mem-swap", severity: .warning, icon: "memorychip",
                title: "\(Fmtish.gb(s.memory.swapUsed)) of swap in use",
                detail: "Frequent swapping adds SSD writes. Closing memory-hungry apps helps."))
        }

        // Thermals
        if s.system.thermalLevel == .critical || s.system.thermalLevel == .serious {
            recs.append(.init(id: "thermal", severity: s.system.thermalLevel == .critical ? .critical : .warning,
                icon: "thermometer.high",
                title: "Your Mac is running hot (\(s.system.thermalLevel.rawValue))",
                detail: "Reduce load, improve airflow, or move off soft surfaces to avoid throttling."))
        }

        // Disk nearly full
        if let root = s.disk.volumes.first(where: { $0.mountPoint == "/" }), root.usagePercent > 90 {
            recs.append(.init(id: "disk-full", severity: .warning, icon: "internaldrive",
                title: "Startup disk is \(Int(root.usagePercent))% full",
                detail: "Free up space — a nearly-full SSD slows down and has less room for wear-leveling."))
        }

        // Drive S.M.A.R.T. / endurance
        for d in s.disk.drives {
            if !d.isHealthy {
                recs.append(.init(id: "smart-\(d.id)", severity: .critical, icon: "exclamationmark.triangle",
                    title: "\(d.name) reports a S.M.A.R.T. warning",
                    detail: "Back up this drive now — it may be failing."))
            } else if let life = d.lifeRemaining, life < 20 {
                recs.append(.init(id: "ssd-life-\(d.id)", severity: .warning, icon: "internaldrive",
                    title: "\(d.name) is at \(life)% life remaining",
                    detail: "The SSD is wearing out — keep backups and plan a replacement."))
            }
        }

        // Battery health
        if s.battery.isPresent {
            if s.battery.health > 0 && s.battery.health < 80 {
                recs.append(.init(id: "batt-health", severity: .info, icon: "battery.25",
                    title: "Battery health is \(Int(s.battery.health))%",
                    detail: "Capacity has dropped — a battery service would restore runtime."))
            }
            if s.battery.condition.localizedCaseInsensitiveContains("service") {
                recs.append(.init(id: "batt-service", severity: .warning, icon: "battery.25",
                    title: "Battery needs service",
                    detail: "macOS flagged the battery condition — consider a replacement."))
            }
        }

        return recs.sorted { $0.severity.rawValue > $1.severity.rawValue }
    }

    /// macOS system services / agents that should never be suggested for quitting,
    /// even when they're owned by the logged-in user (Dock, Finder, …) or surfaced via
    /// the helper without ownership info. The uid check already excludes root daemons in
    /// the direct build; this also covers user-owned system UI agents and the helper path.
    private static let systemProcessNames: Set<String> = [
        "windowserver", "kernel_task", "launchd", "logd", "mds", "mds_stores",
        "mdworker", "mdworker_shared", "mdbulkimport", "backupd", "coreaudiod",
        "hidd", "bluetoothd", "powerd", "configd", "cfprefsd", "distnoted",
        "notifyd", "securityd", "trustd", "syspolicyd", "nsurlsessiond", "cloudd",
        "bird", "apsd", "identityservicesd", "spindump", "reportcrash",
        "corespotlightd", "suggestd", "parsecd", "photoanalysisd", "photolibraryd",
        "mediaanalysisd", "mediaremoted", "symptomsd", "locationd", "sharingd",
        "rapportd", "useractivityd", "universalaccessd", "airportd",
        "dock", "finder", "systemuiserver", "controlcenter", "controlcenterhelper",
        "notificationcenter", "spotlight", "loginwindow", "talagent", "windowmanager",
        "wallpaper", "wallpaperagent", "dockhelper",
    ]

    private static func isSystemProcess(_ name: String) -> Bool {
        systemProcessNames.contains(name.lowercased())
    }
}

/// Tiny local byte formatter (avoids depending on the view-layer Fmt here).
enum Fmtish {
    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

// MARK: - Aggregate

struct SystemSnapshot: Sendable {
    var cpu: CPUStats = CPUStats()
    var memory: MemoryStats = MemoryStats()
    var disk: DiskStats = DiskStats()
    var gpu: GPUStats = GPUStats()
    var network: NetworkStats = NetworkStats()
    var battery: BatteryStats = BatteryStats()
    var fans: FanStats = FanStats()
    var system: SystemInfo = SystemInfo()
    var topProcessesByCPU: [ProcessInfo] = []
    var topProcessesByMemory: [ProcessInfo] = []
    var timestamp: Date = Date()
}
