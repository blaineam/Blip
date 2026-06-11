import Foundation

// MARK: - Metric Catalog
//
// The full inventory of metrics Blip exposes to Shortcuts, mapped from the
// monitors in Services/ (CPU, memory, disk + S.M.A.R.T., GPU, network,
// battery, SMC temps/fans, system). Pure data + pure mapping functions so the
// catalog is unit-testable without any live monitor.
//
// History honesty: Blip keeps a 60-sample in-memory ring per charted metric,
// sampled every 2 s — i.e. roughly the last TWO MINUTES, only while the app is
// running, never persisted. Average/min/max statistics are therefore offered
// only for those charted metrics and only over that window; everything else
// is current-value only.

/// Stable identifiers for every metric Blip exposes. Raw values are the
/// AppEntity ids — never rename them (saved Shortcuts reference them).
enum MetricID: String, CaseIterable, Sendable {
    // CPU
    case cpuUsage = "cpu.usage"
    case cpuUser = "cpu.user"
    case cpuSystem = "cpu.system"
    case cpuLoad1 = "cpu.load1"
    case cpuLoad5 = "cpu.load5"
    case cpuLoad15 = "cpu.load15"
    // Memory
    case memoryUsage = "memory.usage"
    case memoryUsed = "memory.used"
    case memoryFree = "memory.free"
    case memorySwapUsed = "memory.swap"
    case memoryPressure = "memory.pressure"
    // Disk
    case diskUsage = "disk.usage"
    case diskFree = "disk.free"
    case diskRead = "disk.read"
    case diskWrite = "disk.write"
    case diskTotalRead = "disk.totalread"
    case diskTotalWritten = "disk.totalwritten"
    case smartHealthy = "disk.smartok"
    case ssdLife = "disk.ssdlife"
    case driveTemperature = "disk.temp"
    // GPU
    case gpuUsage = "gpu.usage"
    // Network
    case netDown = "net.down"
    case netUp = "net.up"
    case netPing = "net.ping"
    case netRouterPing = "net.routerping"
    case netTotalDown = "net.totaldown"
    case netTotalUp = "net.totalup"
    // Battery
    case batteryLevel = "battery.level"
    case batteryHealth = "battery.health"
    case batteryCycles = "battery.cycles"
    case batteryTemperature = "battery.temp"
    case batteryMinutesRemaining = "battery.minutesleft"
    // Temps / fans (SMC; unavailable in the sandboxed build without the helper)
    case cpuTemperature = "temp.cpu"
    case gpuTemperature = "temp.gpu"
    case fanRPM = "fan.rpm"
    // System
    case uptime = "system.uptime"
    case thermalLevel = "system.thermal"
}

/// The canonical unit of each metric's raw `Double` value (what Shortcuts
/// receives when chaining the result).
enum MetricUnit: Sendable {
    case percent
    case bytes
    case bytesPerSecond
    case milliseconds
    case celsius
    case count
    case rpm
    case seconds
    case minutes
    /// Discrete severity level (memory pressure 0–4, thermal 0–3).
    case level
}

struct MetricDescriptor: Sendable {
    let id: MetricID
    let title: String
    let unit: MetricUnit
    let symbol: String        // SF Symbol for display representations
    /// True when SystemMonitor keeps a 60×2s history ring for this metric, so
    /// average/min/max over the last ~2 minutes are honest to offer.
    let hasHistory: Bool
}

enum MetricCatalog {
    static let all: [MetricDescriptor] = [
        .init(id: .cpuUsage, title: "CPU Usage", unit: .percent, symbol: "cpu", hasHistory: true),
        .init(id: .cpuUser, title: "CPU Usage (User)", unit: .percent, symbol: "cpu", hasHistory: false),
        .init(id: .cpuSystem, title: "CPU Usage (System)", unit: .percent, symbol: "cpu", hasHistory: false),
        .init(id: .cpuLoad1, title: "Load Average (1 min)", unit: .count, symbol: "gauge", hasHistory: false),
        .init(id: .cpuLoad5, title: "Load Average (5 min)", unit: .count, symbol: "gauge", hasHistory: false),
        .init(id: .cpuLoad15, title: "Load Average (15 min)", unit: .count, symbol: "gauge", hasHistory: false),

        .init(id: .memoryUsage, title: "Memory Usage", unit: .percent, symbol: "memorychip", hasHistory: true),
        .init(id: .memoryUsed, title: "Memory Used", unit: .bytes, symbol: "memorychip", hasHistory: false),
        .init(id: .memoryFree, title: "Memory Free", unit: .bytes, symbol: "memorychip", hasHistory: false),
        .init(id: .memorySwapUsed, title: "Swap Used", unit: .bytes, symbol: "memorychip", hasHistory: false),
        .init(id: .memoryPressure, title: "Memory Pressure Level", unit: .level, symbol: "memorychip", hasHistory: false),

        .init(id: .diskUsage, title: "Startup Disk Usage", unit: .percent, symbol: "internaldrive", hasHistory: false),
        .init(id: .diskFree, title: "Startup Disk Free Space", unit: .bytes, symbol: "internaldrive", hasHistory: false),
        .init(id: .diskRead, title: "Disk Read Speed", unit: .bytesPerSecond, symbol: "internaldrive", hasHistory: true),
        .init(id: .diskWrite, title: "Disk Write Speed", unit: .bytesPerSecond, symbol: "internaldrive", hasHistory: true),
        .init(id: .diskTotalRead, title: "Disk Total Read (since boot)", unit: .bytes, symbol: "internaldrive", hasHistory: false),
        .init(id: .diskTotalWritten, title: "Disk Total Written (since boot)", unit: .bytes, symbol: "internaldrive", hasHistory: false),
        .init(id: .smartHealthy, title: "S.M.A.R.T. Healthy (1 = yes)", unit: .count, symbol: "checkmark.shield", hasHistory: false),
        .init(id: .ssdLife, title: "SSD Life Remaining", unit: .percent, symbol: "internaldrive", hasHistory: false),
        .init(id: .driveTemperature, title: "Drive Temperature", unit: .celsius, symbol: "thermometer", hasHistory: false),

        .init(id: .gpuUsage, title: "GPU Usage", unit: .percent, symbol: "cpu.fill", hasHistory: true),

        .init(id: .netDown, title: "Network Download Speed", unit: .bytesPerSecond, symbol: "arrow.down.circle", hasHistory: true),
        .init(id: .netUp, title: "Network Upload Speed", unit: .bytesPerSecond, symbol: "arrow.up.circle", hasHistory: true),
        .init(id: .netPing, title: "Ping", unit: .milliseconds, symbol: "dot.radiowaves.left.and.right", hasHistory: false),
        .init(id: .netRouterPing, title: "Router Ping", unit: .milliseconds, symbol: "wifi.router", hasHistory: false),
        .init(id: .netTotalDown, title: "Network Total Downloaded (since boot)", unit: .bytes, symbol: "arrow.down.circle", hasHistory: false),
        .init(id: .netTotalUp, title: "Network Total Uploaded (since boot)", unit: .bytes, symbol: "arrow.up.circle", hasHistory: false),

        .init(id: .batteryLevel, title: "Battery Level", unit: .percent, symbol: "battery.75", hasHistory: false),
        .init(id: .batteryHealth, title: "Battery Health", unit: .percent, symbol: "battery.100", hasHistory: false),
        .init(id: .batteryCycles, title: "Battery Cycle Count", unit: .count, symbol: "battery.50", hasHistory: false),
        .init(id: .batteryTemperature, title: "Battery Temperature", unit: .celsius, symbol: "thermometer", hasHistory: false),
        .init(id: .batteryMinutesRemaining, title: "Battery Time Remaining", unit: .minutes, symbol: "battery.25", hasHistory: false),

        .init(id: .cpuTemperature, title: "CPU Temperature", unit: .celsius, symbol: "thermometer", hasHistory: false),
        .init(id: .gpuTemperature, title: "GPU Temperature", unit: .celsius, symbol: "thermometer", hasHistory: false),
        .init(id: .fanRPM, title: "Fan Speed (fastest fan)", unit: .rpm, symbol: "fan", hasHistory: false),

        .init(id: .uptime, title: "Uptime", unit: .seconds, symbol: "clock", hasHistory: false),
        .init(id: .thermalLevel, title: "Thermal Pressure Level", unit: .level, symbol: "thermometer.high", hasHistory: false),
    ]

    static func descriptor(for id: MetricID) -> MetricDescriptor {
        // The catalog covers every MetricID case (asserted by unit tests).
        all.first { $0.id == id }!
    }

    static func descriptor(forRawID raw: String) -> MetricDescriptor? {
        MetricID(rawValue: raw).map(descriptor(for:))
    }
}

// MARK: - Mapping (snapshot → value)

enum MetricMapper {
    /// Extracts a metric's current value from a snapshot. Returns nil when the
    /// hardware doesn't report it (no battery, no SMC temps in the sandboxed
    /// build, ping not yet measured, …).
    static func value(of id: MetricID, in s: SystemSnapshot) -> Double? {
        switch id {
        case .cpuUsage: return s.cpu.totalUsage
        case .cpuUser: return s.cpu.userUsage
        case .cpuSystem: return s.cpu.systemUsage
        case .cpuLoad1: return s.cpu.loadAverage1
        case .cpuLoad5: return s.cpu.loadAverage5
        case .cpuLoad15: return s.cpu.loadAverage15

        case .memoryUsage: return s.memory.usagePercent
        case .memoryUsed: return Double(s.memory.used)
        case .memoryFree: return Double(s.memory.free)
        case .memorySwapUsed: return Double(s.memory.swapUsed)
        case .memoryPressure: return Double(s.memory.pressureLevel)

        case .diskUsage:
            guard let root = s.disk.volumes.first(where: { $0.mountPoint == "/" }) ?? s.disk.volumes.first
            else { return nil }
            return root.usagePercent
        case .diskFree:
            guard let root = s.disk.volumes.first(where: { $0.mountPoint == "/" }) ?? s.disk.volumes.first
            else { return nil }
            return Double(root.freeBytes)
        case .diskRead: return Double(s.disk.readBytesPerSec)
        case .diskWrite: return Double(s.disk.writeBytesPerSec)
        case .diskTotalRead: return Double(s.disk.totalBytesRead)
        case .diskTotalWritten: return Double(s.disk.totalBytesWritten)
        case .smartHealthy:
            if !s.disk.drives.isEmpty { return s.disk.drives.allSatisfy(\.isHealthy) ? 1 : 0 }
            let status = s.disk.smartStatus
            guard !status.isEmpty else { return nil }
            return status.localizedCaseInsensitiveContains("verified") ? 1 : 0
        case .ssdLife:
            let lives = s.disk.drives.compactMap(\.lifeRemaining)
            return lives.min().map(Double.init)
        case .driveTemperature:
            let temps = s.disk.drives.compactMap(\.temperatureCelsius)
            return temps.max().map(Double.init)

        case .gpuUsage: return s.gpu.utilization

        case .netDown: return Double(s.network.downloadSpeed)
        case .netUp: return Double(s.network.uploadSpeed)
        case .netPing: return s.network.pingMs
        case .netRouterPing: return s.network.routerPingMs
        case .netTotalDown: return Double(s.network.totalBytesDownloaded)
        case .netTotalUp: return Double(s.network.totalBytesUploaded)

        case .batteryLevel: return s.battery.isPresent ? s.battery.level : nil
        case .batteryHealth: return s.battery.isPresent && s.battery.health > 0 ? s.battery.health : nil
        case .batteryCycles: return s.battery.isPresent ? Double(s.battery.cycleCount) : nil
        case .batteryTemperature: return s.battery.isPresent && s.battery.temperature > 0 ? s.battery.temperature : nil
        case .batteryMinutesRemaining:
            guard s.battery.isPresent, s.battery.timeRemaining >= 0 else { return nil }
            return Double(s.battery.timeRemaining)

        case .cpuTemperature: return s.fans.cpuTemperature
        case .gpuTemperature: return s.fans.gpuTemperature
        case .fanRPM: return s.fans.fans.map(\.currentRPM).max().map(Double.init)

        case .uptime: return s.system.uptime
        case .thermalLevel:
            switch s.system.thermalLevel {
            case .nominal: return 0
            case .fair: return 1
            case .serious: return 2
            case .critical: return 3
            }
        }
    }

    /// Reduces a history window (oldest-first samples) with a statistic.
    /// Returns nil for an empty window.
    static func reduce(_ samples: [Double], statistic: MetricStatisticKind) -> Double? {
        guard !samples.isEmpty else { return nil }
        switch statistic {
        case .current: return samples.last
        case .average: return samples.reduce(0, +) / Double(samples.count)
        case .minimum: return samples.min()
        case .maximum: return samples.max()
        }
    }
}

/// Pure twin of the AppEnum statistic (kept AppIntents-free so mapping logic
/// stays testable without the framework).
enum MetricStatisticKind: String, CaseIterable, Sendable {
    case current, average, minimum, maximum
}

// MARK: - Formatting

enum MetricFormatter {
    /// Human string for a metric value, e.g. "37.2%", "1.24 GB/s", "843 MB".
    static func format(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .percent: return String(format: "%.1f%%", value)
        case .bytes: return bytes(value)
        case .bytesPerSecond: return bytes(value) + "/s"
        case .milliseconds: return String(format: "%.1f ms", value)
        case .celsius: return String(format: "%.0f°C", value)
        case .count: return value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
        case .rpm: return String(format: "%.0f RPM", value)
        case .seconds: return duration(value)
        case .minutes: return duration(value * 60)
        case .level: return String(format: "%.0f", value)
        }
    }

    private static func bytes(_ v: Double) -> String {
        let abs = Swift.abs(v)
        switch abs {
        case ..<1_000: return String(format: "%.0f B", v)
        case ..<1_000_000: return String(format: "%.1f KB", v / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f MB", v / 1_000_000)
        case ..<1_000_000_000_000: return String(format: "%.2f GB", v / 1_000_000_000)
        default: return String(format: "%.2f TB", v / 1_000_000_000_000)
        }
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
