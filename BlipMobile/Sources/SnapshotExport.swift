import Foundation

// One-file "everything Blip knows right now" export (#feedback: "a button to save a snapshot
// of all stats in one file"). Markdown: pasteable into an issue, a chat, a wiki — and still
// diffable. Written to tmp under a timestamped name; ShareLink hands it anywhere.

enum SnapshotExport {
    static func markdown(for s: DeviceSnapshot, speedHistory: [MobileSpeedResult]?) -> String {
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        var md = """
        # Blip Snapshot — \(s.marketingName)
        _\(stamp)_

        ## Device
        | | |
        |---|---|
        | Model | \(s.marketingName) (`\(s.model)`) |
        | OS | \(s.osVersion) |
        | Booted | \(s.bootDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—") |
        | Uptime | \(Fmt.uptime(s.bootUptime ?? s.uptime)) (awake \(Fmt.uptime(s.uptime))) |
        | Cores | \(s.coresPerformance > 0 ? "\(s.coresTotal) (\(s.coresPerformance)P + \(s.coresEfficiency)E)" : "\(s.coresTotal)") |
        | Thermal | \(s.thermalLabel) |
        | Battery | \(s.batteryLevel.map { "\(Int($0 * 100))%" } ?? "—") · \(s.batteryState)\(s.lowPowerMode ? " · Low Power" : "") |

        ## CPU
        | | |
        |---|---|
        | Usage | \(Int(s.cpuUsagePercent))% |
        | Load 1/5/15 | \(String(format: "%.2f / %.2f / %.2f", s.load1, s.load5, s.load15)) |

        ## Memory
        | | |
        |---|---|
        | Physical | \(Fmt.memory(Int64(s.memoryPhysical))) |
        | Available to apps | \(Fmt.memory(Int64(s.memoryAppAvailable))) |
        | Free | \(Fmt.memory(Int64(s.memFree))) |
        | Active | \(Fmt.memory(Int64(s.memActive))) |
        | Inactive | \(Fmt.memory(Int64(s.memInactive))) |
        | Wired | \(Fmt.memory(Int64(s.memWired))) |
        | Compressed | \(Fmt.memory(Int64(s.memCompressed))) |
        | Blip's footprint | \(Fmt.memory(Int64(s.appFootprint))) |

        ## Storage
        | | |
        |---|---|
        | Used | \(Int(s.storagePercentUsed))% |
        | Free | \(Fmt.bytes(s.storageFree)) of \(Fmt.bytes(s.storageTotal)) |
        | Free if caches purge | \(Fmt.bytes(s.storageOpportunistic)) |

        ## Network
        | | |
        |---|---|
        | Interface | \(s.interfaceType)\(s.radioTech.map { " (\($0))" } ?? "") |
        | Path | \(pathFlags(s)) |
        | VPN | \(s.vpnActive ? "Active" : "Not detected") |
        """
        if !s.localIPs.isEmpty {
            md += "\n\n### Local addresses\n"
            for ip in s.localIPs { md += "- `\(ip)`\n" }
        }
        if let history = speedHistory, !history.isEmpty {
            md += "\n## Recent speed tests\n"
            for r in history.suffix(5).reversed() {
                let up = r.upMbps.map { String(format: " / %.0f up", $0) } ?? ""
                md += "- \(r.date.formatted(date: .abbreviated, time: .shortened)): \(String(format: "%.0f", r.downMbps)) Mbps down\(up) — \(r.source) on \(r.interface)\n"
            }
        }
        md += "\n---\n_Captured by Blip · blip.wemiller.com_\n"
        return md
    }

    private static func pathFlags(_ s: DeviceSnapshot) -> String {
        var f: [String] = []
        if s.isExpensivePath { f.append("metered") }
        if s.isConstrainedPath { f.append("low data mode") }
        return f.isEmpty ? "unrestricted" : f.joined(separator: ", ")
    }

    /// Write to tmp and hand back the URL for ShareLink. Named so a pile of snapshots sorts.
    static func file(for s: DeviceSnapshot, speedHistory: [MobileSpeedResult]?) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Blip-Snapshot-\(fmt.string(from: Date())).md")
        try? markdown(for: s, speedHistory: speedHistory).data(using: .utf8)?.write(to: url)
        return url
    }
}
