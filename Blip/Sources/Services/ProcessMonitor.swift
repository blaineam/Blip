import Foundation
import AppKit
import Darwin

final class ProcessMonitor: @unchecked Sendable {
    private let iconCache = NSCache<NSNumber, NSData>()
    private var previousCPUTimes: [pid_t: (user: UInt64, system: UInt64, wallNs: UInt64)] = [:]

    /// Mach absolute time → nanoseconds conversion factor.
    /// pti_total_user/system are in Mach ticks; multiply by this to get nanoseconds.
    private let machToNs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    init() {
        iconCache.countLimit = 10
        iconCache.totalCostLimit = 2 * 1024 * 1024
    }

    func read() async -> (byCPU: [ProcessInfo], byMemory: [ProcessInfo]) {
        let parsed = readAllProcesses()

        let byCPU = Array(parsed.sorted { $0.cpu > $1.cpu }.prefix(5))
        let byMemory = Array(parsed.sorted { $0.memory > $1.memory }.prefix(5))

        // Dedupe PIDs and fetch icons + proper names only for visible processes
        var seenPIDs = Set<pid_t>()
        var allVisible: [ProcessInfo] = []
        for p in byCPU + byMemory {
            if seenPIDs.insert(p.id).inserted {
                allVisible.append(p)
            }
        }

        var iconMap: [pid_t: Data?] = [:]
        var nameMap: [pid_t: String] = [:]
        for p in allVisible {
            let app = NSRunningApplication(processIdentifier: p.id)
            iconMap[p.id] = appIcon(for: p.id)
            if let displayName = app?.localizedName, !displayName.isEmpty {
                nameMap[p.id] = displayName
            } else {
                nameMap[p.id] = procName(for: p.id) ?? p.name
            }
        }

        let byCPUWithIcons = byCPU.map { p in
            ProcessInfo(id: p.id, name: nameMap[p.id] ?? p.name, cpu: p.cpu, memory: p.memory, icon: iconMap[p.id] ?? nil)
        }
        let byMemWithIcons = byMemory.map { p in
            ProcessInfo(id: p.id, name: nameMap[p.id] ?? p.name, cpu: p.cpu, memory: p.memory, icon: iconMap[p.id] ?? nil)
        }

        // Prune stale PIDs from the delta cache
        let activePIDs = Set(parsed.map { $0.id })
        previousCPUTimes = previousCPUTimes.filter { activePIDs.contains($0.key) }

        return (byCPUWithIcons, byMemWithIcons)
    }

    private func readAllProcesses() -> [ProcessInfo] {
        // Get all PIDs
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let pidCount = Int(bufferSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: pidCount)
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return [] }

        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size
        let myPid = getpid()
        let nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC)

        // Collect ps-based CPU for ALL processes (including system/root processes
        // that proc_pidinfo can't read). We'll prefer our delta-based values when available.
        let psCPU = readPSCPU()

        var results: [ProcessInfo] = []
        var directPIDs = Set<pid_t>()

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0, pid != myPid else { continue }

            // Get task info for CPU time
            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)
            guard ret == taskInfoSize else { continue }

            // Get physical footprint for memory (matches Activity Monitor)
            let memory = physFootprint(for: pid)
            guard memory > 0 else { continue }

            // Delta-based CPU calculation
            let currentUser = taskInfo.pti_total_user
            let currentSystem = taskInfo.pti_total_system
            var cpuPercent: Double = 0

            if let prev = previousCPUTimes[pid] {
                let userDelta = currentUser > prev.user ? currentUser - prev.user : 0
                let systemDelta = currentSystem > prev.system ? currentSystem - prev.system : 0
                let wallDeltaNs = nowNs > prev.wallNs ? nowNs - prev.wallNs : 1

                if wallDeltaNs > 0 {
                    // pti_total_user/system are in Mach absolute time ticks;
                    // convert to nanoseconds before comparing with wall clock ns
                    let cpuTimeNs = Double(userDelta + systemDelta) * machToNs
                    let wallTimeNs = Double(wallDeltaNs)
                    cpuPercent = (cpuTimeNs / wallTimeNs) * 100
                }
            }

            previousCPUTimes[pid] = (user: currentUser, system: currentSystem, wallNs: nowNs)

            // Get process name
            var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            proc_pidpath(pid, &nameBuffer, UInt32(nameBuffer.count))
            let pathLen = Int(strlen(nameBuffer))
            let path = String(decoding: nameBuffer.prefix(pathLen).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = (path as NSString).lastPathComponent

            guard !name.isEmpty, (cpuPercent > 0.1 || memory > 1_048_576) else { continue }

            directPIDs.insert(pid)
            results.append(ProcessInfo(id: pid, name: name, cpu: cpuPercent, memory: memory, icon: nil))
        }

        // Merge in system processes from ps that we couldn't read via proc_pidinfo
        for entry in psCPU where !directPIDs.contains(entry.pid) && entry.cpu > 0.5 {
            results.append(ProcessInfo(id: entry.pid, name: entry.name, cpu: entry.cpu, memory: 0, icon: nil))
        }

        return results
    }

    /// Reads CPU% for all processes via `ps`. This works for system processes
    /// (WindowServer, etc.) that proc_pidinfo can't access without root.
    private func readPSCPU() -> [(pid: pid_t, cpu: Double, name: String)] {
        let task = Foundation.Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,%cpu,comm"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return []
        }
        // Read pipe data BEFORE waitUntilExit to avoid deadlock
        // when output exceeds the pipe buffer size
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [(pid: pid_t, cpu: Double, name: String)] = []
        for line in output.components(separatedBy: "\n").dropFirst() {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]) else { continue }
            let fullPath = String(parts[2])
            let name = (fullPath as NSString).lastPathComponent
            results.append((pid: pid, cpu: cpu, name: name))
        }
        return results
    }

    private func physFootprint(for pid: pid_t) -> UInt64 {
        var rusage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rusagePtr)
            }
        }
        guard result == 0 else { return 0 }
        return rusage.ri_phys_footprint
    }

    private func appIcon(for pid: pid_t) -> Data? {
        let key = NSNumber(value: pid)
        if let cached = iconCache.object(forKey: key) {
            return cached as Data
        }

        guard let app = NSRunningApplication(processIdentifier: pid),
              let icon = app.icon else {
            return nil
        }

        // Render at 16×16 (half previous 32×32) — sufficient for process row display
        let smallIcon = NSImage(size: NSSize(width: 16, height: 16))
        smallIcon.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16),
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .copy,
                  fraction: 1.0)
        smallIcon.unlockFocus()

        guard let tiff = smallIcon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        iconCache.setObject(pngData as NSData, forKey: key, cost: pngData.count)
        return pngData
    }

    private func procName(for pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_name(pid, &name, UInt32(name.count))
        guard len > 0 else { return nil }
        let length = Int(len)
        return String(decoding: name.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
