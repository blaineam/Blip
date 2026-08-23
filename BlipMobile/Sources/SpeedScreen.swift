import SwiftUI

// The Speed tab, second edition. Source menu chooses the public OpenSpeedTest service or
// your own server (address lives in Settings, with a link straight to it); results keep a
// capped history; any result can go out the share sheet as an image + text.

struct SpeedScreen: View {
    @ObservedObject var tester: MobileSpeedTester
    @ObservedObject var stats: DeviceStats
    @State private var liveCurve: [Double] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pathBanner
                    sourceMenu
                    gauge
                    if tester.isRunning || !liveCurve.isEmpty {
                        Sparkline(values: liveCurve, tint: .teal, height: 60)
                            .onChange(of: tester.phase) { _, phase in
                                if phase == .download { liveCurve = [] }
                            }
                    }
                    runButton
                    if let r = tester.lastResult, !tester.isRunning {
                        resultCard(r, isLatest: true)
                    }
                    historySection
                }
                .padding()
            }
            .navigationTitle("Speed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsScreen() } label: { Image(systemName: "gearshape") }
                }
            }
        }
    }

    private var pathBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: stats.snapshot.interfaceType == "Cellular"
                  ? "antenna.radiowaves.left.and.right" : "wifi")
            Text("Testing over \(stats.snapshot.interfaceType)")
            if stats.snapshot.isExpensivePath {
                Text("· metered").foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: - Source (#feedback: dropdown for public vs configured, with a configure link)

    private var sourceMenu: some View {
        HStack {
            Menu {
                Picker("Source", selection: $tester.source) {
                    ForEach(SpeedSource.allCases) { source in
                        if source == .custom && MobileSpeedTester.customServer.isEmpty {
                            // still selectable — the run button explains what's missing
                            Label(source.label, systemImage: "exclamationmark.circle").tag(source)
                        } else {
                            Text(sourceTitle(source)).tag(source)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tester.source == .publicWidget ? "globe" : "server.rack")
                    Text(sourceTitle(tester.source))
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .disabled(tester.isRunning)
            Spacer()
            NavigationLink { SettingsScreen() } label: {
                Text(MobileSpeedTester.customServer.isEmpty && tester.source == .custom
                     ? "Set server…" : "Configure")
                    .font(.footnote)
            }
        }
    }

    private func sourceTitle(_ source: SpeedSource) -> String {
        switch source {
        case .publicWidget: return "OpenSpeedTest (public)"
        case .custom:
            let server = MobileSpeedTester.customServer
            return server.isEmpty ? "My server (not set)" : server
        }
    }

    // MARK: - Gauge

    private var gauge: some View {
        VStack(spacing: 4) {
            Text(tester.isRunning ? String(format: "%.0f", tester.liveMbps)
                                  : tester.lastResult.map { String(format: "%.0f", $0.downMbps) } ?? "—")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(phaseLabel)
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onChange(of: tester.liveMbps) { _, mbps in
            guard tester.isRunning, mbps > 0 else { return }
            liveCurve.append(mbps)
            if liveCurve.count > 120 { liveCurve.removeFirst() }
        }
    }

    private var phaseLabel: String {
        switch tester.phase {
        case .idle: return "Mbps"
        case .connecting: return "Connecting…"
        case .download: return "Mbps · downloading"
        case .upload: return "Mbps · uploading"
        case .done: return "Mbps · down"
        case .failed(let why): return why
        }
    }

    private var runButton: some View {
        Button {
            tester.toggle(interface: stats.snapshot.interfaceType)
        } label: {
            Text(tester.isRunning ? "Cancel" : "Run Speed Test")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tester.isRunning ? .red : .teal)
    }

    // MARK: - Results + history

    @ViewBuilder
    private var historySection: some View {
        let older = tester.history.dropLast()
        if !older.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("History").font(.headline)
                ForEach(older.reversed()) { r in
                    resultCard(r, isLatest: false)
                }
            }
        }
    }

    private func resultCard(_ r: MobileSpeedResult, isLatest: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Label(String(format: "%.0f Mbps", r.downMbps), systemImage: "arrow.down")
                if let up = r.upMbps {
                    Label(String(format: "%.0f Mbps", up), systemImage: "arrow.up")
                }
                if let ping = r.pingMs {
                    Label(String(format: "%.0f ms", ping), systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(isLatest ? .system(.body, design: .rounded).weight(.semibold)
                           : .system(.subheadline, design: .rounded))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(r.date.formatted(date: .abbreviated, time: .shortened))
                Text("\(r.source) · \(r.interface)").lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            ShareLink(
                item: SharePayload(image: ShareCard.render(SpeedShareCardView(result: r)) ?? UIImage(),
                                   text: ShareCard.speedText(r)),
                preview: SharePreview(String(format: "%.0f Mbps", r.downMbps),
                                      image: Image(uiImage: ShareCard.render(SpeedShareCardView(result: r)) ?? UIImage()))
            ) {
                Image(systemName: "square.and.arrow.up").font(.callout)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.quaternary.opacity(isLatest ? 0.5 : 0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}
