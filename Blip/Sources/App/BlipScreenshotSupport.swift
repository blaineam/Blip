//
//  BlipScreenshotSupport.swift
//  Blip
//
//  App Store screenshot automation. Activated by launch args
//  `-BlipScreenshotMode 1 -BlipScreenshotScene <section>`. Injects a fixed,
//  entirely fictional snapshot (no real system data, no PII — no MAC/serial/
//  public-IP/real process names) so screenshots are reproducible and safe.
//  Inert in normal runs: nothing here executes unless the launch arg is present.
//

import Foundation

enum BlipScreenshotMode {
    static let isActive: Bool =
        Foundation.ProcessInfo.processInfo.arguments.contains("-BlipScreenshotMode")
        || UserDefaults.standard.bool(forKey: "BlipScreenshotMode")

    /// popover (overview) or a section: cpu, memory, disk, network, gpu, thermal, battery
    static var scene: String {
        let args = Foundation.ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-BlipScreenshotScene"), i + 1 < args.count {
            return args[i + 1]
        }
        return UserDefaults.standard.string(forKey: "BlipScreenshotScene") ?? "popover"
    }

    static var section: PopoverSection? { PopoverSection(rawValue: scene) }
}

// MARK: - Fictional demo snapshot

extension SystemSnapshot {
    /// A realistic, healthy, completely fictional snapshot for screenshots.
    static func demo() -> SystemSnapshot {
        var s = SystemSnapshot()

        // CPU — Apple silicon 12-core (8P + 4E), moderate load.
        s.cpu.totalUsage = 31
        s.cpu.userUsage = 21
        s.cpu.systemUsage = 10
        s.cpu.coreUsages = [58, 44, 22, 17, 71, 39, 12, 9, 6, 4, 8, 3]
        s.cpu.loadAverage1 = 2.4
        s.cpu.loadAverage5 = 2.1
        s.cpu.loadAverage15 = 1.8
        s.cpu.physicalCores = 12
        s.cpu.logicalCores = 12
        s.cpu.performanceCores = 8
        s.cpu.efficiencyCores = 4

        // Memory — 36 GB, comfortable usage.
        s.memory.total = 36 * 1_073_741_824
        s.memory.used = 19 * 1_073_741_824
        s.memory.free = 17 * 1_073_741_824
        s.memory.wired = 4 * 1_073_741_824
        s.memory.compressed = 2 * 1_073_741_824
        s.memory.appMemory = 13 * 1_073_741_824
        s.memory.cachedFiles = 6 * 1_073_741_824
        s.memory.swapUsed = 0
        s.memory.swapTotal = 2 * 1_073_741_824
        s.memory.pressureLevel = 0

        // GPU — helper-only (utilization/temperature). Left empty; the App Store
        // build hides the GPU row when the helper isn't connected.
        s.gpu.name = "Apple GPU"

        // Disk — only volume usage is available without the helper. Disk I/O and
        // S.M.A.R.T. drive health are helper-only, so they're left empty.
        s.disk.volumes = [
            VolumeInfo(name: "Macintosh HD", mountPoint: "/",
                       totalBytes: 1_000_000_000_000, freeBytes: 612_000_000_000)
        ]

        // Network — Wi-Fi, private LAN only (no public IP / MAC).
        s.network.isConnected = true
        s.network.interfaceName = "Wi-Fi"
        s.network.downloadSpeed = 4_200_000
        s.network.uploadSpeed = 680_000
        s.network.lanAddress = "192.168.1.42"
        s.network.wanAddress = "—"
        s.network.routerIP = "192.168.1.1"
        s.network.macAddress = "—"
        s.network.pingMs = 11
        s.network.routerPingMs = 2
        s.network.totalBytesDownloaded = 412_000_000_000
        s.network.totalBytesUploaded = 88_000_000_000
        s.network.interfaces = [
            InterfaceInfo(id: "en0", name: "Wi-Fi", ipv4: "192.168.1.42",
                          ipv6: "—", macAddress: "—", isActive: true)
        ]

        // Battery — only level / charging state are available without the helper.
        // Health, cycle count, condition and temperature are helper-only.
        s.battery.isPresent = true
        s.battery.level = 84
        s.battery.isCharging = false
        s.battery.timeRemaining = 372
        s.battery.powerSource = "Battery"

        // Fans + SMC temperatures are helper-only — left empty.

        // Process monitoring is helper-only — top-process lists left empty.

        // System info.
        s.system.uptime = 3 * 86_400 + 5 * 3_600 + 12 * 60
        s.system.thermalLevel = .nominal
        s.system.blipMemoryMB = 41.6
        s.system.blipCPU = 0.3
        s.system.macModel = "MacBook Pro"
        s.system.macOSVersion = "macOS 15.0"

        s.timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        return s
    }
}

// MARK: - Monitor injection

extension SystemMonitor {
    /// Load the fictional demo snapshot + plausible history curves and skip all
    /// real polling. Used only in screenshot mode.
    func loadDemoData() {
        let snap = SystemSnapshot.demo()

        func curve(_ base: Double, _ amp: Double, _ phase: Double) -> HistoryBuffer<Double> {
            var b = HistoryBuffer<Double>(capacity: 60, defaultValue: base)
            for i in 0..<60 {
                let t = Double(i)
                let v = base + amp * sin(t / 7 + phase) + amp * 0.4 * sin(t / 2.3 + phase * 2)
                b.append(max(0, v))
            }
            return b
        }

        snapshot = snap
        cpuHistory = curve(31, 16, 0.0)
        memoryHistory = curve(53, 6, 1.1)
        gpuHistory = curve(26, 18, 2.0)
        diskReadHistory = curve(40, 30, 0.7)
        diskWriteHistory = curve(18, 14, 1.7)
        netDownHistory = curve(45, 28, 0.3)
        netUpHistory = curve(12, 9, 2.4)
        recommendations = []
    }
}
