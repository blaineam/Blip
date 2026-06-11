import Foundation
@testable import Blip

// MARK: - Shared test fixtures

/// Mock monitor behind the MetricSource seam — no IOKit, no subprocesses.
@MainActor
final class MockMetricSource: MetricSource {
    var snapshot = SystemSnapshot()
    var histories: [MetricID: [Double]] = [:]
    private(set) var ensureFreshSampleCalls = 0

    var metricSnapshot: SystemSnapshot { snapshot }

    func metricHistory(_ id: MetricID) -> [Double]? { histories[id] }

    func ensureFreshSample() async { ensureFreshSampleCalls += 1 }
}

enum Fixtures {
    /// A fully-populated snapshot with distinctive values per metric so
    /// mapping tests can detect crossed wires.
    static func snapshot() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.cpu.totalUsage = 42.5
        s.cpu.userUsage = 30.25
        s.cpu.systemUsage = 12.25
        s.cpu.loadAverage1 = 1.5
        s.cpu.loadAverage5 = 2.5
        s.cpu.loadAverage15 = 3.5

        s.memory.total = 32_000_000_000
        s.memory.used = 16_000_000_000
        s.memory.free = 16_000_000_000
        s.memory.swapUsed = 1_000_000_000
        s.memory.pressureLevel = 1

        s.disk.volumes = [
            VolumeInfo(name: "Macintosh HD", mountPoint: "/", totalBytes: 1_000_000_000_000, freeBytes: 250_000_000_000),
            VolumeInfo(name: "Scratch", mountPoint: "/Volumes/Scratch", totalBytes: 2_000_000_000_000, freeBytes: 1_500_000_000_000),
        ]
        s.disk.readBytesPerSec = 120_000_000
        s.disk.writeBytesPerSec = 80_000_000
        s.disk.totalBytesRead = 9_000_000_000_000
        s.disk.totalBytesWritten = 7_000_000_000_000
        s.disk.smartStatus = "Verified"
        s.disk.drives = [drive(name: "APPLE SSD", percentageUsed: 8, tempC: 41, healthy: true)]

        s.gpu.utilization = 17.5

        s.network.downloadSpeed = 12_500_000
        s.network.uploadSpeed = 2_500_000
        s.network.pingMs = 12.5
        s.network.routerPingMs = 1.25
        s.network.totalBytesDownloaded = 123_000_000_000
        s.network.totalBytesUploaded = 45_000_000_000

        s.battery.isPresent = true
        s.battery.level = 84
        s.battery.health = 92
        s.battery.cycleCount = 312
        s.battery.temperature = 30.5
        s.battery.timeRemaining = 245

        s.fans.cpuTemperature = 55.5
        s.fans.gpuTemperature = 48.25
        s.fans.fans = [
            FanInfo(id: 0, name: "Left", currentRPM: 1_800, minRPM: 1_200, maxRPM: 5_900),
            FanInfo(id: 1, name: "Right", currentRPM: 2_100, minRPM: 1_200, maxRPM: 5_900),
        ]

        s.system.uptime = 93_784   // 1d 2h 3m 4s
        s.system.thermalLevel = .fair
        return s
    }

    static func drive(name: String, percentageUsed: Int?, tempC: Int?, healthy: Bool) -> DriveHealth {
        DriveHealth(
            name: name,
            bsdName: "disk0",
            isInternal: true,
            medium: "NVMe",
            smartStatus: healthy ? "Verified" : "Failing",
            percentageUsed: percentageUsed,
            availableSpare: 100,
            availableSpareThreshold: 10,
            temperatureCelsius: tempC,
            bytesWritten: 1_000_000_000_000,
            bytesRead: 2_000_000_000_000,
            powerOnHours: 1_234,
            powerCycles: 456,
            unsafeShutdowns: 7,
            mediaErrors: 0,
            criticalWarning: healthy ? 0 : 1
        )
    }

    static func hop(_ n: Int, host: String, sent: Int, recv: Int, avg: Double?) -> HelperTraceHop {
        let loss = sent > 0 ? Double(sent - recv) / Double(sent) * 100 : 0
        return HelperTraceHop(hop: n, host: host, sent: sent, recv: recv,
                              lossPct: loss, lastMs: avg, avgMs: avg,
                              bestMs: avg, worstMs: avg)
    }

    /// A scratch, isolated defaults suite (cleared by the caller).
    static func scratchDefaults(_ name: String) -> UserDefaults {
        let suite = "com.blainemiller.BlipTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
}
