import SwiftUI
import AppKit

// macOS share layer — iOS parity (field request): share a bench result, a speed result,
// or a one-file snapshot of everything, each as a rendered image + accompanying text.
// ShareLink drives the system share sheet; ImageRenderer draws the same dark branded
// cards the iOS app ships.

/// Rendered image + caption for ShareLink (PNG + text proxy).
struct MacSharePayload: Transferable {
    let image: NSImage
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { payload in
            guard let tiff = payload.image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return Data() }
            return png
        }
        ProxyRepresentation { (payload: MacSharePayload) in payload.text }
    }
}

@MainActor
enum MacShareCard {
    static func render<V: View>(_ view: V, width: CGFloat = 700) -> NSImage? {
        let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, .dark))
        renderer.scale = 2
        return renderer.nsImage
    }

    static func benchText(_ r: BenchResult, deviceName: String) -> String {
        var lines = ["Blip Bench — \(deviceName)",
                     "Composite \(Int(r.composite.rounded())) (\(r.profile == .quick ? "quick" : "full") run)",
                     "Single-core \(Int(r.singleCore.score.rounded())) · All cores \(Int(r.multiCore.score.rounded())) · Memory \(Int(r.memory.score.rounded()))"]
        if let gpu = r.gpu { lines[2] += " · GPU \(Int(gpu.score.rounded()))" }
        if let neural = r.neural { lines[2] += " · Neural \(Int(neural.score.rounded()))" }
        if let lost = r.throttlePercentLost {
            lines.append(lost == 0 ? "No throttling under sustained load" : "Sustained load loses \(lost)%")
        }
        lines.append("Measured with Blip · blip.wemiller.com")
        return lines.joined(separator: "\n")
    }

    static func speedText(_ r: NetSpeedResult) -> String {
        var l = "Network speed — \(String(format: "%.0f", r.downMbps)) Mbps down"
        if let up = r.upMbps { l += " · \(String(format: "%.0f", up)) Mbps up" }
        if let ping = r.pingMs { l += " · \(String(format: "%.0f", ping)) ms idle" }
        if let loaded = r.loadedPingMs { l += " · \(String(format: "%.0f", loaded)) ms loaded" }
        let grades = ConnectionGrades.evaluate(down: r.downMbps, up: r.upMbps,
                                               unloadedMs: r.pingMs, loadedMs: r.loadedPingMs)
        return l + "\n" + ConnectionGrades.shareLines(grades) + "\nMeasured with Blip · blip.wemiller.com"
    }
}

// MARK: - Cards (same visual language as the iOS share cards)

struct MacBenchShareCardView: View {
    let result: BenchResult
    let deviceName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Blip Bench", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(deviceName).font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int(result.composite.rounded()))")
                    .font(.system(size: 84, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.purple, .blue],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 2) {
                    Text("composite").font(.headline)
                    Text(result.profile == .quick ? "quick run" : "full run")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                pill("cpu", "Single", result.singleCore.score)
                pill("square.grid.3x3", "Multi", result.multiCore.score)
                pill("memorychip", "Memory", result.memory.score)
                if let gpu = result.gpu { pill("cube.transparent", "GPU", gpu.score) }
                if let neural = result.neural { pill("brain", "Neural", neural.score) }
            }
            HStack {
                if let lost = result.throttlePercentLost {
                    Label(lost == 0 ? "No thermal throttling" : "Sustained −\(lost)%",
                          systemImage: lost > 15 ? "flame.fill" : "flame")
                        .font(.footnote)
                        .foregroundStyle(lost > 15 ? .orange : .secondary)
                }
                Spacer()
                Text(result.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .background(Color(red: 0.09, green: 0.09, blue: 0.13))
        .foregroundStyle(.white)
    }

    private func pill(_ icon: String, _ name: LocalizedStringKey, _ score: Double) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.callout)
            Text("\(Int(score.rounded()))")
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MacSpeedShareCardView: View {
    let result: NetSpeedResult
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Blip Speed", systemImage: "speedometer")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            HStack(spacing: 24) {
                metric("arrow.down", String(format: "%.0f", result.downMbps), "Mbps down", .teal)
                if let up = result.upMbps {
                    metric("arrow.up", String(format: "%.0f", up), "Mbps up", .orange)
                }
                if let ping = result.pingMs {
                    metric("clock", String(format: "%.0f", ping), "ms idle", .secondary)
                }
                Spacer()
            }
            if let down = result.downCurve, !down.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    DualCurveChart(down: down, up: result.upCurve ?? [], height: 80)
                    HStack(spacing: 12) {
                        Label("download", systemImage: "arrow.down").foregroundStyle(.teal)
                        Label("upload", systemImage: "arrow.up").foregroundStyle(.orange)
                        Spacer()
                        if let ping = result.pingMs, let loaded = result.loadedPingMs {
                            Text(String(format: "%.0f ms idle → %.0f ms loaded", ping, loaded))
                                .foregroundStyle(loaded - ping > 100 ? .orange : .secondary)
                        }
                    }
                    .font(.caption2)
                }
            }
            gradeRow
            HStack {
                Spacer()
                Text(result.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .background(Color(red: 0.07, green: 0.11, blue: 0.13))
        .foregroundStyle(.white)
    }

    private var gradeRow: some View {
        let grades = ConnectionGrades.evaluate(down: result.downMbps, up: result.upMbps,
                                               unloadedMs: result.pingMs, loadedMs: result.loadedPingMs)
        return HStack(spacing: 8) {
            ForEach(grades) { g in
                VStack(spacing: 3) {
                    Text(g.grade.rawValue)
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .foregroundStyle(g.grade.tint)
                    Image(systemName: g.icon).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func metric(_ icon: String, _ value: String, _ unit: LocalizedStringKey, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: icon).font(.callout).foregroundStyle(tint)
            Text(value).font(.system(size: 44, weight: .bold, design: .rounded))
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - The all-stats snapshot

enum MacSnapshotExport {
    static func markdown(_ s: SystemSnapshot, speedHistory: [NetSpeedResult]) -> String {
        func gb(_ v: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory) }
        func fileGB(_ v: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) }
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        var md = """
        # Blip Snapshot — \(s.system.macModel.isEmpty ? "Mac" : s.system.macModel)
        _\(stamp)_

        ## System
        | | |
        |---|---|
        | Model | \(s.system.macModel) |
        | macOS | \(s.system.macOSVersion) |
        | Uptime | \(Fmt.uptime(s.system.uptime)) |
        | Thermal | \(s.system.thermalLevel) |
        | Blip's footprint | \(String(format: "%.0f MB · %.1f%% CPU", s.system.blipMemoryMB, s.system.blipCPU)) |

        ## CPU
        | | |
        |---|---|
        | Usage | \(String(format: "%.0f%%", s.cpu.totalUsage)) (user \(String(format: "%.0f%%", s.cpu.userUsage)), system \(String(format: "%.0f%%", s.cpu.systemUsage))) |
        | Cores | \(s.cpu.logicalCores) (\(s.cpu.performanceCores)P + \(s.cpu.efficiencyCores)E) |
        | Load 1/5/15 | \(String(format: "%.2f / %.2f / %.2f", s.cpu.loadAverage1, s.cpu.loadAverage5, s.cpu.loadAverage15)) |

        ## Memory
        | | |
        |---|---|
        | Used | \(gb(s.memory.used)) of \(gb(s.memory.total)) |
        | App memory | \(gb(s.memory.appMemory)) |
        | Wired | \(gb(s.memory.wired)) |
        | Compressed | \(gb(s.memory.compressed)) |
        | Cached files | \(gb(s.memory.cachedFiles)) |
        | Swap | \(gb(s.memory.swapUsed)) of \(gb(s.memory.swapTotal)) |

        ## GPU
        | | |
        |---|---|
        | \(s.gpu.name) | \(String(format: "%.0f%%", s.gpu.utilization)) · \(s.gpu.coreCount) cores |

        ## Network
        | | |
        |---|---|
        | Interface | \(s.network.interfaceName.isEmpty ? "—" : s.network.interfaceName) |
        | LAN | \(s.network.lanAddress) |
        | Router | \(s.network.routerIP)\(s.network.routerPingMs.map { String(format: " (%.0f ms)", $0) } ?? "") |
        | VPN | \(s.network.isVPNActive ? "Active (\(s.network.vpnInterface))" : "Not detected") |
        | Throughput | ↓ \(fileGB(s.network.downloadSpeed))/s · ↑ \(fileGB(s.network.uploadSpeed))/s |

        ## Storage
        """
        for v in s.disk.volumes {
            md += "\n- **\(v.name)** — \(fileGB(v.freeBytes)) free of \(fileGB(v.totalBytes))"
        }
        if s.battery.isPresent {
            md += """
            \n
            ## Battery
            | | |
            |---|---|
            | Level | \(String(format: "%.0f%%", s.battery.level)) (\(s.battery.isCharging ? "charging" : s.battery.powerSource)) |
            | Health | \(String(format: "%.0f%%", s.battery.health)) · \(s.battery.cycleCount) cycles · \(s.battery.condition) |
            """
        }
        if !s.fans.fans.isEmpty || s.fans.cpuTemperature != nil {
            md += "\n\n## Fans & Thermals\n"
            for f in s.fans.fans { md += "- \(f.currentRPM) rpm (\(f.minRPM)–\(f.maxRPM))\n" }
            if let c = s.fans.cpuTemperature { md += "- CPU \(String(format: "%.0f °C", c))\n" }
            if let g = s.fans.gpuTemperature { md += "- GPU \(String(format: "%.0f °C", g))\n" }
        }
        if !speedHistory.isEmpty {
            md += "\n## Recent speed tests\n"
            for r in speedHistory.suffix(5).reversed() {
                let up = r.upMbps.map { String(format: " / %.0f up", $0) } ?? ""
                md += "- \(r.timestamp.formatted(date: .abbreviated, time: .shortened)): \(String(format: "%.0f", r.downMbps)) Mbps down\(up)\n"
            }
        }
        md += "\n---\n_Captured by Blip · blip.wemiller.com_\n"
        return md
    }

    static func file(_ s: SystemSnapshot, speedHistory: [NetSpeedResult]) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Blip-Snapshot-\(fmt.string(from: Date())).md")
        try? markdown(s, speedHistory: speedHistory).data(using: .utf8)?.write(to: url)
        return url
    }
}


/// Lazy snapshot payload: the Markdown file is produced only when the user actually
/// shares (a plain `ShareLink(item: URL)` would write a temp file on every popover
/// body evaluation — once every 2-second tick while open).
struct SnapshotFilePayload: Transferable {
    let snapshot: SystemSnapshot
    let speedHistory: [NetSpeedResult]
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { payload in
            SentTransferredFile(MacSnapshotExport.file(payload.snapshot, speedHistory: payload.speedHistory))
        }
        ProxyRepresentation { (payload: SnapshotFilePayload) in
            MacSnapshotExport.markdown(payload.snapshot, speedHistory: payload.speedHistory)
        }
    }
}
