import Foundation
import Combine
import Darwin
import IOKit
import SwiftUI

/// Central coordinator that polls all hardware monitors on a timer
/// and publishes unified snapshots for the UI layer.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    @Published var cpuHistory = HistoryBuffer<Double>(capacity: 60, defaultValue: 0)
    @Published var memoryHistory = HistoryBuffer<Double>(capacity: 60, defaultValue: 0)
    @Published var gpuHistory = HistoryBuffer<Double>(capacity: 60, defaultValue: 0)
    @Published var diskReadHistory = HistoryBuffer<Double>(capacity: 60, defaultValue: 0)
    @Published var diskWriteHistory = HistoryBuffer<Double>(capacity: 60, defaultValue: 0)
    @Published var netDownHistory = HistoryBuffer<Double>(capacity: 60, defaultValue: 0)
    @Published var netUpHistory = HistoryBuffer<Double>(capacity: 60, defaultValue: 0)

    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let diskMonitor = DiskMonitor()
    private let gpuMonitor = GPUMonitor()
    private let networkMonitor = NetworkMonitor()
    private let batteryMonitor = BatteryMonitor()
    private let fanMonitor = FanMonitor()
    private let processMonitor = ProcessMonitor()

    private var pollTask: Task<Void, Never>?
    private var diskPollCount = 0
    private var cachedModelName: String?
    @AppStorage("pingTarget") private var pingTarget: String = "1.1.1.1"

    /// Polling interval in seconds
    let interval: TimeInterval = 2.0

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            // Do an initial read immediately
            await self.poll()
            // Then poll on interval
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.interval))
                guard !Task.isCancelled else { break }
                await self.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        // Pass user's ping target preference to network monitor
        networkMonitor.pingTarget = pingTarget.isEmpty ? "1.1.1.1" : pingTarget

        // Run fast monitors concurrently
        async let cpuRead = Task.detached { [cpuMonitor] in cpuMonitor.read() }.value
        async let memRead = Task.detached { [memoryMonitor] in memoryMonitor.read() }.value
        async let netRead = Task.detached { [networkMonitor] in networkMonitor.read() }.value
        async let gpuRead = Task.detached { [gpuMonitor] in gpuMonitor.read() }.value
        async let battRead = batteryMonitor.read()
        async let fanRead = fanMonitor.read()
        async let procRead = Task.detached { [processMonitor] in await processMonitor.read() }.value

        let cpu = await cpuRead
        let memory = await memRead
        let network = await netRead
        let gpu = await gpuRead
        let battery = await battRead
        let fans = await fanRead
        let procs = await procRead

        // Disk is slow — poll every 5th cycle (10 seconds)
        diskPollCount += 1
        let disk: DiskStats
        if diskPollCount % 5 == 1 {
            disk = await Task.detached { [diskMonitor] in diskMonitor.read() }.value
        } else {
            disk = snapshot.disk
        }

        // System info (uptime, thermal, self-usage)
        let sysInfo = readSystemInfo()

        var newSnapshot = SystemSnapshot()
        newSnapshot.cpu = cpu
        newSnapshot.memory = memory
        newSnapshot.disk = disk
        newSnapshot.gpu = gpu
        newSnapshot.network = network
        newSnapshot.battery = battery
        newSnapshot.fans = fans
        newSnapshot.system = sysInfo
        newSnapshot.topProcessesByCPU = procs.byCPU
        newSnapshot.topProcessesByMemory = procs.byMemory
        newSnapshot.timestamp = Date()

        snapshot = newSnapshot
        cpuHistory.append(cpu.totalUsage)
        memoryHistory.append(memory.usagePercent)
        gpuHistory.append(gpu.utilization)
        diskReadHistory.append(Double(disk.readBytesPerSec))
        diskWriteHistory.append(Double(disk.writeBytesPerSec))
        netDownHistory.append(Double(network.downloadSpeed))
        netUpHistory.append(Double(network.uploadSpeed))
    }

    private func readSystemInfo() -> SystemInfo {
        var info = SystemInfo()

        // Uptime
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &boottime, &size, nil, 0) == 0 {
            info.uptime = Date().timeIntervalSince1970 - Double(boottime.tv_sec)
        }

        // Thermal state
        let thermalState = Foundation.ProcessInfo.processInfo.thermalState
        switch thermalState {
        case .nominal: info.thermalLevel = .nominal
        case .fair: info.thermalLevel = .fair
        case .serious: info.thermalLevel = .serious
        case .critical: info.thermalLevel = .critical
        @unknown default: info.thermalLevel = .nominal
        }

        // Mac model — use cached marketing name from system_profiler
        if let cached = cachedModelName {
            info.macModel = cached
        } else {
            // Run system_profiler once to get the marketing model name
            let modelName = Self.fetchMarketingModelName()
            cachedModelName = modelName
            info.macModel = modelName
        }

        // macOS version
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        info.macOSVersion = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        // Blip's own resource usage
        var rusage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rusagePtr)
            }
        }
        if result == 0 {
            info.blipMemoryMB = Double(rusage.ri_phys_footprint) / 1_048_576
        }

        return info
    }

    /// Fetches the marketing model name via system_profiler (e.g. "MacBook Pro (16-inch, Nov 2024)")
    private static func fetchMarketingModelName() -> String {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPHardwareDataType"] as? [[String: Any]],
               let first = items.first {
                let modelName = first["machine_name"] as? String ?? ""
                let chipType = first["chip_type"] as? String ?? ""
                if !modelName.isEmpty && !chipType.isEmpty {
                    return "\(modelName) (\(chipType))"
                } else if !modelName.isEmpty {
                    return modelName
                }
            }
        } catch {
            // Fall through to sysctl fallback
        }
        // Fallback to hw.model
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            return String(decoding: model.prefix(size).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return "Mac"
    }
}
