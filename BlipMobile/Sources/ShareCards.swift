import SwiftUI

// Share-sheet payloads (#feedback: "a share sheet that creates an image and accompanying
// text"). ImageRenderer draws a self-contained card — dark, branded, legible in any feed —
// and the text carries the same numbers for places where images get stripped.

enum ShareCard {
    @MainActor
    static func render<V: View>(_ view: V, width: CGFloat = 700) -> UIImage? {
        let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, .dark))
        renderer.scale = 3
        return renderer.uiImage
    }

    static func benchText(_ r: BenchResult) -> String {
        var lines = ["Blip Bench — \(DeviceNames.name(for: r.deviceModel))",
                     "Composite \(Int(r.composite.rounded())) (\(r.profile == .quick ? "quick" : "full") run)",
                     "Single-core \(Int(r.singleCore.score.rounded())) · All cores \(Int(r.multiCore.score.rounded())) · Memory \(Int(r.memory.score.rounded()))"]
        if let gpu = r.gpu { lines[2] += " · GPU \(Int(gpu.score.rounded()))" }
        if let lost = r.throttlePercentLost {
            lines.append(lost == 0 ? "No throttling under sustained load" : "Sustained load loses \(lost)%")
        }
        lines.append("Measured with Blip · blip.wemiller.com")
        return lines.joined(separator: "\n")
    }

    static func speedText(_ r: MobileSpeedResult) -> String {
        var l = "Network speed — \(String(format: "%.0f", r.downMbps)) Mbps down"
        if let up = r.upMbps { l += " · \(String(format: "%.0f", up)) Mbps up" }
        if let ping = r.pingMs { l += " · \(String(format: "%.0f", ping)) ms ping" }
        return l + "\nvia \(r.source) on \(r.interface)\nMeasured with Blip · blip.wemiller.com"
    }
}

struct BenchShareCardView: View {
    let result: BenchResult
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Blip Bench", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(DeviceNames.name(for: result.deviceModel))
                    .font(.callout).foregroundStyle(.secondary)
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

    private func pill(_ icon: String, _ name: String, _ score: Double) -> some View {
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

struct SpeedShareCardView: View {
    let result: MobileSpeedResult
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Blip Speed", systemImage: "speedometer")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(result.interface).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                metric("arrow.down", String(format: "%.0f", result.downMbps), "Mbps down", .teal)
                if let up = result.upMbps {
                    metric("arrow.up", String(format: "%.0f", up), "Mbps up", .blue)
                }
                if let ping = result.pingMs {
                    metric("clock", String(format: "%.0f", ping), "ms ping", .secondary)
                }
                Spacer()
            }
            HStack {
                Text("via \(result.source)").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(result.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .background(Color(red: 0.07, green: 0.11, blue: 0.13))
        .foregroundStyle(.white)
    }

    private func metric(_ icon: String, _ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: icon).font(.callout).foregroundStyle(tint)
            Text(value).font(.system(size: 44, weight: .bold, design: .rounded))
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Wraps a rendered image + caption for ShareLink; Transferable via the UIImage's PNG.
struct SharePayload: Transferable {
    let image: UIImage
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { payload in
            payload.image.pngData() ?? Data()
        }
        ProxyRepresentation { (payload: SharePayload) in payload.text }
    }
}
