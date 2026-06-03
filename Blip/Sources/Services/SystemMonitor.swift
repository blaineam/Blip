import Foundation
import Combine
import Darwin
import SwiftUI

/// Central coordinator that polls all hardware monitors on a timer
/// and publishes unified snapshots for the UI layer.
///
/// For privileged data (SMC, IOKit, proc_*), the in-process monitors
/// are tried first. If they return empty results (e.g. when sandboxed),
/// the HelperClient fills in the gaps from BlipHelper over TCP.
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

    /// Helper client for privileged data when running sandboxed.
    /// Only activated when the app is inside an App Sandbox.
    let helperClient = HelperClient()

    /// True when the app is running inside App Sandbox (MAS version).
    /// The direct-download version is unsandboxed and never needs the helper.
    private let isSandboxed: Bool = {
        Foundation.ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }()

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

    // MARK: - Kill Process (Feature A)

    /// Terminate a process. In sandboxed builds this routes through the helper;
    /// in the unsandboxed direct build we can signal user-owned processes directly.
    func killProcess(pid: pid_t, force: Bool) async -> (ok: Bool, message: String) {
        #if APPSTORE
        guard helperClient.isHelperInstalled else {
            return (false, "Helper not installed")
        }
        return await helperClient.killProcess(pid: pid, force: force)
        #else
        let result = kill(pid, force ? SIGKILL : SIGTERM)
        if result == 0 { return (true, force ? "Force killed" : "Terminated") }
        switch errno {
        case EPERM: return (false, "Permission denied (system process)")
        case ESRCH: return (false, "Process no longer running")
        default:    return (false, "Failed (errno \(errno))")
        }
        #endif
    }

    // MARK: - Traceroute / MTR (Feature B)
    //
    // Routed through the helper: the sandboxed MAS app cannot spawn
    // /usr/sbin/traceroute, and the unsandboxed direct build uses the same
    // path for consistency (falling back to a local run only if no helper).

    // The direct (unsandboxed) build always runs traceroute in-process — it's
    // self-sufficient and avoids depending on a possibly-stale or not-running helper.
    // Only the sandboxed App Store build routes through the helper.

    /// Start a continuous traceroute session against `host`.
    func startTraceroute(host: String) async {
        #if APPSTORE
        await helperClient.startTraceroute(host: host)
        #else
        localTrace.start(host: host)
        #endif
    }

    /// Stop the active traceroute session.
    func stopTraceroute() async {
        #if APPSTORE
        await helperClient.stopTraceroute()
        #else
        localTrace.stop()
        #endif
    }

    /// Fetch the current per-hop stats + running flag.
    func tracerouteHops() async -> (hops: [HelperTraceHop], running: Bool) {
        #if APPSTORE
        return await helperClient.tracerouteHops()
        #else
        return localTrace.snapshot()
        #endif
    }

    #if !APPSTORE
    /// Local traceroute runner used by the unsandboxed build when no helper is present.
    private let localTrace = LocalTraceRunner()
    #endif

    private func poll() async {
        // Pass user's ping target preference to network monitor
        networkMonitor.pingTarget = pingTarget.isEmpty ? "1.1.1.1" : pingTarget

        // Run monitors concurrently.
        // In the App Store build, GPU/fan/process monitors are no-ops (helper provides
        // this data), so skip spawning threads for them to reduce CPU overhead.
        async let cpuRead = Task.detached { [cpuMonitor] in cpuMonitor.read() }.value
        async let memRead = Task.detached { [memoryMonitor] in memoryMonitor.read() }.value
        async let netRead = Task.detached { [networkMonitor] in networkMonitor.read() }.value
        async let battRead = batteryMonitor.read()
        #if APPSTORE
        let gpuRead = gpuMonitor.read()     // No IOKit work, just returns cached name/cores
        let fanRead = FanStats()            // SMC stubbed out, returns empty
        let procRead: (byCPU: [ProcessInfo], byMemory: [ProcessInfo]) = ([], [])
        // Only poll helper if it appears to be installed
        if isSandboxed && helperClient.isHelperInstalled {
            await helperClient.poll()
        }
        #else
        async let gpuRead = Task.detached { [gpuMonitor] in gpuMonitor.read() }.value
        async let fanRead = fanMonitor.read()
        async let procRead = Task.detached { [processMonitor] in await processMonitor.read() }.value
        #endif

        let helper = isSandboxed ? helperClient.latestSnapshot : nil

        let cpu = await cpuRead
        let memory = await memRead
        var network = await netRead
        #if APPSTORE
        var gpu = gpuRead
        var battery = await battRead
        var fans = fanRead
        let procs = procRead
        #else
        var gpu = await gpuRead
        var battery = await battRead
        var fans = await fanRead
        let procs = await procRead
        #endif

        // Disk is slow — poll every 5th cycle (10 seconds)
        diskPollCount += 1
        var disk: DiskStats
        if diskPollCount % 5 == 1 {
            disk = await Task.detached { [diskMonitor] in diskMonitor.read() }.value
        } else {
            disk = snapshot.disk
        }

        // Merge helper data for privileged metrics.
        // In-process monitors succeed when unsandboxed; when sandboxed they
        // return empty/zero and the helper fills in the gaps.
        var topByCPU = procs.byCPU
        var topByMemory = procs.byMemory

        if let h = helper {
            // Fans/thermal: use helper if in-process SMC returned nothing
            if fans.fans.isEmpty && !h.fans.isEmpty {
                fans.fans = h.fans.map { FanInfo(id: $0.id, name: $0.name, currentRPM: $0.currentRPM, minRPM: $0.minRPM, maxRPM: $0.maxRPM) }
            }
            if fans.cpuTemperature == nil { fans.cpuTemperature = h.cpuTemperature }
            if fans.gpuTemperature == nil { fans.gpuTemperature = h.gpuTemperature }

            // GPU utilization: use helper if in-process IOKit returned 0
            if gpu.utilization == 0 && h.gpuUtilization > 0 {
                gpu.utilization = h.gpuUtilization
            }

            // Disk I/O: use helper if in-process returned 0
            if disk.readBytesPerSec == 0 && disk.writeBytesPerSec == 0 {
                disk.readBytesPerSec = h.diskReadBytesPerSec
                disk.writeBytesPerSec = h.diskWriteBytesPerSec
                disk.totalBytesRead = h.diskTotalBytesRead
                disk.totalBytesWritten = h.diskTotalBytesWritten
            }
            if disk.smartStatus.isEmpty && !h.smartStatus.isEmpty {
                disk.smartStatus = h.smartStatus
            }

            // Since-boot network totals from the helper (sandboxed app can't run netstat)
            if let down = h.networkTotalDownloaded, down > 0 {
                network.totalBytesDownloaded = down
            }
            if let up = h.networkTotalUploaded, up > 0 {
                network.totalBytesUploaded = up
            }

            // Per-drive S.M.A.R.T. health (NVMe health log via the helper)
            if disk.drives.isEmpty, let helperDrives = h.drives, !helperDrives.isEmpty {
                disk.drives = helperDrives.map {
                    DriveHealth(
                        name: $0.name,
                        bsdName: $0.bsdName,
                        isInternal: $0.isInternal,
                        medium: $0.medium,
                        smartStatus: $0.smartStatus,
                        percentageUsed: $0.percentageUsed,
                        availableSpare: $0.availableSpare,
                        availableSpareThreshold: $0.availableSpareThreshold,
                        temperatureCelsius: $0.temperatureCelsius,
                        bytesWritten: $0.bytesWritten,
                        bytesRead: $0.bytesRead,
                        powerOnHours: $0.powerOnHours,
                        powerCycles: $0.powerCycles,
                        unsafeShutdowns: $0.unsafeShutdowns,
                        mediaErrors: $0.mediaErrors,
                        criticalWarning: $0.criticalWarning
                    )
                }
            }

            // Battery health: use helper if in-process returned defaults
            if battery.health == 0 { battery.health = h.batteryHealth ?? 0 }
            if battery.cycleCount == 0 { battery.cycleCount = h.batteryCycleCount ?? 0 }
            if battery.condition.isEmpty { battery.condition = h.batteryCondition ?? "" }
            if battery.temperature == 0 { battery.temperature = h.batteryTemperature ?? 0 }

            // Processes: use helper if in-process proc_* returned empty
            if topByCPU.isEmpty && !h.topProcessesByCPU.isEmpty {
                topByCPU = h.topProcessesByCPU.map {
                    ProcessInfo(id: $0.pid, name: $0.name, cpu: $0.cpu, memory: $0.memory, icon: $0.icon)
                }
            }
            if topByMemory.isEmpty && !h.topProcessesByMemory.isEmpty {
                topByMemory = h.topProcessesByMemory.map {
                    ProcessInfo(id: $0.pid, name: $0.name, cpu: $0.cpu, memory: $0.memory, icon: $0.icon)
                }
            }
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
        newSnapshot.topProcessesByCPU = topByCPU
        newSnapshot.topProcessesByMemory = topByMemory
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

        // Mac model — try helper's marketing name first (MAS build),
        // then fall back to in-process fetch
        if let cached = cachedModelName {
            info.macModel = cached
        } else if let helperModel = helperClient.latestSnapshot?.macModelName, !helperModel.isEmpty {
            cachedModelName = helperModel
            info.macModel = helperModel
        } else {
            let modelName = Self.fetchMarketingModelName()
            cachedModelName = modelName
            info.macModel = modelName
        }

        // macOS version
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        info.macOSVersion = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        // Blip's own memory footprint
        #if APPSTORE
        // Use task_info (public Mach API, sandbox-safe)
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &vmCount)
            }
        }
        if vmResult == KERN_SUCCESS {
            info.blipMemoryMB = Double(vmInfo.phys_footprint) / 1_048_576
        }
        #else
        // proc_pid_rusage (private API, not permitted on App Store)
        var rusage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rusagePtr)
            }
        }
        if result == 0 {
            info.blipMemoryMB = Double(rusage.ri_phys_footprint) / 1_048_576
        }
        #endif

        return info
    }

    /// Fetches the marketing model name.
    /// On the direct-download version, uses system_profiler for the full name.
    /// On the App Store version, uses the sysctl hw.model fallback only.
    private static func fetchMarketingModelName() -> String {
        #if !APPSTORE
        // system_profiler subprocess — not permitted on App Store
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
        #endif
        // hw.model via sysctl (public API, safe for App Store)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            let identifier = String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Try to resolve the marketing name from the identifier
            if let marketing = Self.modelLookup[identifier] {
                return marketing
            }
            return identifier
        }
        return "Mac"
    }

    /// Compact model lookup: "id:product,chip,year" tuples decoded at init.
    /// Keeps binary small — ~1.5 KB vs ~3.5 KB for full string dictionary.
    private static let modelLookup: [String: String] = {
        // Format: "id=type,size,chip,year" — decoded into "Type Size (Chip, Year)"
        // Types: A=MacBook Air, P=MacBook Pro, m=Mac mini, i=iMac, S=Mac Studio, R=Mac Pro
        let entries: [(String, String)] = [
            // M1
            ("MacBookAir10,1", "A,13\",M1,2020"), ("MacBookPro17,1", "P,13\",M1,2020"),
            ("MacBookPro18,1", "P,16\",M1 Pro,2021"), ("MacBookPro18,2", "P,16\",M1 Max,2021"),
            ("MacBookPro18,3", "P,14\",M1 Pro,2021"), ("MacBookPro18,4", "P,14\",M1 Max,2021"),
            ("Macmini9,1", "m,,M1,2020"),
            ("iMac21,1", "i,24\",M1,2021"), ("iMac21,2", "i,24\",M1,2021"),
            ("Mac13,1", "S,,M1 Max,2022"), ("Mac13,2", "S,,M1 Ultra,2022"),
            // M2
            ("Mac14,2", "A,13\",M2,2022"), ("Mac14,15", "A,15\",M2,2023"),
            ("Mac14,7", "P,13\",M2,2022"),
            ("Mac14,5", "P,14\",M2 Pro,2023"), ("Mac14,9", "P,14\",M2 Max,2023"),
            ("Mac14,6", "P,16\",M2 Pro,2023"), ("Mac14,10", "P,16\",M2 Max,2023"),
            ("Mac14,3", "m,,M2,2023"), ("Mac14,12", "m,,M2 Pro,2023"),
            ("Mac14,8", "R,,M2 Ultra,2023"),
            ("Mac14,13", "S,,M2 Max,2023"), ("Mac14,14", "S,,M2 Ultra,2023"),
            // M3
            ("Mac15,3", "P,14\",M3,2023"),
            ("Mac15,12", "A,13\",M3,2024"), ("Mac15,13", "A,15\",M3,2024"),
            ("Mac15,4", "i,24\",M3,2023"), ("Mac15,5", "i,24\",M3,2023"),
            ("Mac15,6", "P,14\",M3 Pro,2023"), ("Mac15,10", "P,14\",M3 Max,2023"),
            ("Mac15,8", "P,14\",M3 Max,2023"),
            ("Mac15,7", "P,16\",M3 Pro,2023"), ("Mac15,11", "P,16\",M3 Max,2023"),
            ("Mac15,9", "P,16\",M3 Max,2023"), ("Mac15,14", "S,,M3 Ultra,2025"),
            // M4
            ("Mac16,1", "P,14\",M4,2024"),
            ("Mac16,8", "P,14\",M4 Pro,2024"), ("Mac16,6", "P,14\",M4 Max,2024"),
            ("Mac16,7", "P,16\",M4 Pro,2024"), ("Mac16,5", "P,16\",M4 Max,2024"),
            ("Mac16,2", "i,24\",M4,2024"), ("Mac16,3", "i,24\",M4,2024"),
            ("Mac16,10", "m,,M4,2024"), ("Mac16,11", "m,,M4 Pro,2024"),
            ("Mac16,9", "S,,M4 Max,2025"),
            ("Mac16,12", "A,13\",M4,2025"), ("Mac16,13", "A,15\",M4,2025"),
        ]
        let types: [Character: String] = ["A": "MacBook Air", "P": "MacBook Pro", "m": "Mac mini", "i": "iMac", "S": "Mac Studio", "R": "Mac Pro"]
        var dict = [String: String](minimumCapacity: entries.count)
        for (id, spec) in entries {
            let parts = spec.split(separator: ",", omittingEmptySubsequences: false)
            let type = types[parts[0].first!] ?? "Mac"
            let size = parts[1].isEmpty ? "" : " \(parts[1])"
            dict[id] = "\(type)\(size) (\(parts[2]), \(parts[3]))"
        }
        return dict
    }()
}

#if !APPSTORE
// MARK: - Local Traceroute Runner (Feature B, unsandboxed fallback)

/// Mirrors the helper's continuous traceroute but runs in-process. Only used
/// by the direct (unsandboxed) build when no BlipHelper is installed.
final class LocalTraceRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var hops: [Int: HopStat] = [:]
    private var thread: Thread?
    private var stopFlag = false
    private var currentHost: String = ""

    private struct HopStat {
        var host: String = "*"
        var sent: Int = 0
        var recv: Int = 0
        var last: Double?
        var best: Double?
        var worst: Double?
        var total: Double = 0
    }

    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func start(host: String) {
        guard Self.isValidHost(host) else { return }
        lock.lock()
        if currentHost == host, thread != nil, !stopFlag { lock.unlock(); return }
        stopFlagLocked(true)
        hops.removeAll()
        currentHost = host
        stopFlag = false
        let t = Thread { [weak self] in self?.runLoop(host: host) }
        t.stackSize = 512 * 1024
        thread = t
        lock.unlock()
        t.start()
    }

    func stop() {
        lock.lock(); stopFlagLocked(true); lock.unlock()
    }

    private func stopFlagLocked(_ value: Bool) {
        stopFlag = value
        if value { thread = nil }
    }

    func snapshot() -> (hops: [HelperTraceHop], running: Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = hops.keys.sorted().map { num -> HelperTraceHop in
            let s = hops[num]!
            let loss = s.sent > 0 ? Double(s.sent - s.recv) / Double(s.sent) * 100 : 0
            let avg = s.recv > 0 ? s.total / Double(s.recv) : nil
            return HelperTraceHop(hop: num, host: s.host, sent: s.sent, recv: s.recv,
                                  lossPct: loss, lastMs: s.last, avgMs: avg,
                                  bestMs: s.best, worstMs: s.worst)
        }
        return (result, !stopFlag && thread != nil)
    }

    private func shouldStop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopFlag
    }

    private func runLoop(host: String) {
        while !shouldStop() {
            runOnePass(host: host)
            for _ in 0..<10 {
                if shouldStop() { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private func runOnePass(host: String) {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        process.arguments = ["-n", "-w", "1", "-q", "1", "-m", "30", host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !shouldStop() else { return }
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") { parseHopLine(line) }
    }

    private func parseHopLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first, let hopNum = Int(first) else { return }

        var hostStr = "*"
        var rtt: Double?
        var i = 1
        while i < tokens.count {
            let tok = tokens[i]
            if tok == "ms", i > 1, let ms = Double(tokens[i - 1]) {
                rtt = ms
            } else if tok != "*" && tok != "ms" && Double(tok) == nil {
                if hostStr == "*" { hostStr = tok }
            }
            i += 1
        }

        lock.lock(); defer { lock.unlock() }
        var stat = hops[hopNum] ?? HopStat()
        if hostStr != "*" { stat.host = hostStr }
        stat.sent += 1
        if let rtt {
            stat.recv += 1
            stat.last = rtt
            stat.total += rtt
            stat.best = stat.best.map { min($0, rtt) } ?? rtt
            stat.worst = stat.worst.map { max($0, rtt) } ?? rtt
        }
        hops[hopNum] = stat
    }
}
#endif
