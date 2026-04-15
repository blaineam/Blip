import Foundation
import AppKit
import Darwin

final class ProcessMonitor: @unchecked Sendable {
    private let iconCache = NSCache<NSNumber, NSImage>()

    init() {
        iconCache.countLimit = 20
        iconCache.totalCostLimit = 5 * 1024 * 1024 // 5 MB max
    }

    func read() async -> (byCPU: [ProcessInfo], byMemory: [ProcessInfo]) {
        let output = await runPS()
        let parsed = parsePS(output)

        // Sort FIRST, then only fetch icons for top 5
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

        // Fetch icons and resolve proper display names for visible processes
        var iconMap: [pid_t: Data?] = [:]
        var nameMap: [pid_t: String] = [:]
        for p in allVisible {
            let app = NSRunningApplication(processIdentifier: p.id)
            iconMap[p.id] = appIcon(for: p.id)
            // Prefer the user-facing app name (e.g. "Google Chrome" instead of "Electron")
            if let displayName = app?.localizedName, !displayName.isEmpty {
                nameMap[p.id] = displayName
            } else {
                // Fallback: use proc_name which gives up to 32 chars
                nameMap[p.id] = procName(for: p.id) ?? p.name
            }
        }

        let byCPUWithIcons = byCPU.map { p in
            ProcessInfo(id: p.id, name: nameMap[p.id] ?? p.name, cpu: p.cpu, memory: p.memory, icon: iconMap[p.id] ?? nil)
        }
        let byMemWithIcons = byMemory.map { p in
            ProcessInfo(id: p.id, name: nameMap[p.id] ?? p.name, cpu: p.cpu, memory: p.memory, icon: iconMap[p.id] ?? nil)
        }

        return (byCPUWithIcons, byMemWithIcons)
    }

    private func runPS() async -> String {
        await withCheckedContinuation { continuation in
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-axwwo", "pid,comm,%cpu,rss"]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    private func parsePS(_ output: String) -> [ProcessInfo] {
        var results: [ProcessInfo] = []
        let lines = output.components(separatedBy: "\n").dropFirst()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = pid_t(parts[0]) else { continue }

            let rest = parts[1]
            let restParts = rest.split(separator: " ", omittingEmptySubsequences: true)
            guard restParts.count >= 3 else { continue }

            let rssStr = restParts[restParts.count - 1]
            let cpuStr = restParts[restParts.count - 2]
            let commParts = restParts[0..<(restParts.count - 2)]
            let commPath = commParts.joined(separator: " ")

            guard let cpu = Double(cpuStr), let rssKB = UInt64(rssStr) else { continue }

            let name = URL(fileURLWithPath: commPath).lastPathComponent

            guard pid > 0, cpu > 0 || rssKB > 1024 else { continue }
            guard name != "Blip" else { continue }

            results.append(ProcessInfo(id: pid, name: name, cpu: cpu, memory: rssKB * 1024, icon: nil))
        }

        return results
    }

    private func appIcon(for pid: pid_t) -> Data? {
        let key = NSNumber(value: pid)
        if let cached = iconCache.object(forKey: key) {
            return pngData(from: cached)
        }

        guard let app = NSRunningApplication(processIdentifier: pid),
              let icon = app.icon else {
            return nil
        }

        // Resize to 32x32 to save memory
        let smallIcon = NSImage(size: NSSize(width: 32, height: 32))
        smallIcon.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32),
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .copy,
                  fraction: 1.0)
        smallIcon.unlockFocus()

        iconCache.setObject(smallIcon, forKey: key, cost: 32 * 32 * 4)
        return pngData(from: smallIcon)
    }

    private func procName(for pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_name(pid, &name, UInt32(name.count))
        guard len > 0 else { return nil }
        let length = Int(len)
        return String(decoding: name.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [.compressionFactor: 0.8])
    }
}
