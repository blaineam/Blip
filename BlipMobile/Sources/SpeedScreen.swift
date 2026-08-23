import SwiftUI

// The Speed tab, second edition. Source menu chooses the public OpenSpeedTest service or
// your own server (address lives in Settings, with a link straight to it); results keep a
// capped history; any result can go out the share sheet as an image + text.

struct SpeedScreen: View {
    @ObservedObject var tester: MobileSpeedTester
    @ObservedObject var stats: DeviceStats

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pathBanner
                    sourceMenu
                    gauge
                    if tester.isRunning || !tester.downCurve.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            DualCurveChart(down: tester.downCurve, up: tester.upCurve, height: 64)
                            HStack(spacing: 12) {
                                Label("download", systemImage: "arrow.down").foregroundStyle(.teal)
                                Label("upload", systemImage: "arrow.up").foregroundStyle(.orange)
                                Spacer()
                            }
                            .font(.caption2)
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
            Text("Testing over \(String(localized: String.LocalizationValue(stats.snapshot.interfaceType)))")
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
        case .publicWidget: return String(localized: "OpenSpeedTest (public)")
        case .custom:
            let server = MobileSpeedTester.customServer
            return server.isEmpty ? String(localized: "My server (not set)") : server
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
    }

    private var phaseLabel: LocalizedStringKey {
        switch tester.phase {
        case .idle: return "Mbps"
        case .connecting: return "Connecting…"
        case .download: return "Mbps · downloading"
        case .upload: return "Mbps · uploading"
        case .done: return "Mbps · down"
        case .failed(let why): return LocalizedStringKey(why)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(String(format: "%.0f Mbps", r.downMbps), systemImage: "arrow.down")
                        .foregroundStyle(isLatest ? .teal : .primary)
                    if let up = r.upMbps {
                        Label(String(format: "%.0f Mbps", up), systemImage: "arrow.up")
                            .foregroundStyle(isLatest ? .orange : .primary)
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
            if let ping = r.pingMs {
                HStack(spacing: 14) {
                    Label(String(format: "%.0f ms idle", ping), systemImage: "clock")
                    if let loaded = r.loadedPingMs {
                        Label(String(format: "%.0f ms under load", loaded), systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(loaded - ping > 100 ? .orange : .secondary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if isLatest, let down = r.downCurve, !down.isEmpty {
                DualCurveChart(down: down, up: r.upCurve ?? [], height: 44)
            }
            if isLatest {
                gradeGrid(ConnectionGrades.evaluate(down: r.downMbps, up: r.upMbps,
                                                    unloadedMs: r.pingMs, loadedMs: r.loadedPingMs))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(isLatest ? 0.5 : 0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    /// "What can you actually do with this connection" — one graded chip per activity.
    private func gradeGrid(_ grades: [CategoryGrade]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reliably good for").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(grades) { g in
                    HStack(spacing: 6) {
                        Text(g.grade.rawValue)
                            .font(.caption.weight(.bold))
                            .frame(width: 20, height: 20)
                            .background(g.grade.tint.opacity(0.2), in: Circle())
                            .foregroundStyle(g.grade.tint)
                        Image(systemName: g.icon).font(.caption2).foregroundStyle(.secondary)
                        Text(g.name).font(.caption)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
