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
    var used: UInt64 = 0
    var free: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var appMemory: UInt64 = 0

    var usagePercent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }
}

// MARK: - Disk

struct DiskStats: Sendable {
    var volumes: [VolumeInfo] = []
    var readBytesPerSec: UInt64 = 0
    var writeBytesPerSec: UInt64 = 0

    var primaryUsagePercent: Double {
        guard let primary = volumes.first else { return 0 }
        return primary.usagePercent
    }
}

struct VolumeInfo: Identifiable, Sendable {
    let id = UUID()
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

// MARK: - GPU

struct GPUStats: Sendable {
    var name: String = "Apple GPU"
    var utilization: Double = 0
    var temperature: Double = 0
    var coreCount: Int = 0
}

// MARK: - Network

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
}

// MARK: - Battery

struct BatteryStats: Sendable {
    var level: Double = 0
    var isCharging: Bool = false
    var cycleCount: Int = 0
    var health: Double = 100
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
