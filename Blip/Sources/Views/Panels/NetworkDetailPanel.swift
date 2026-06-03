import SwiftUI
import Charts

struct NetworkDetailPanel: View {
    let stats: NetworkStats
    let downloadHistory: [Double]
    let uploadHistory: [Double]

    // Feature B — Traceroute / MTR handlers (optional for back-compat).
    var traceStart: ((String) async -> Void)? = nil
    var traceStop: (() async -> Void)? = nil
    var tracePoll: (() async -> (hops: [HelperTraceHop], running: Bool))? = nil

    @State private var wanIP: String? = nil
    @State private var showWAN = false
    @State private var loadingWAN = false
    @State private var showMAC = false
    @State private var showVPNIP = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: stats.isConnected ? "wifi" : "wifi.slash")
                    .foregroundStyle(stats.isConnected ? .cyan : .red)
                Text("Network")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(stats.isConnected ? .green : .red)
                    .frame(width: 6, height: 6)
            }

            // Speeds row
            HStack(spacing: 0) {
                netStatColumn(icon: "arrow.down", iconColor: .green, label: "Download", value: Fmt.speed(stats.downloadSpeed))
                netStatColumn(icon: "arrow.up", iconColor: .blue, label: "Upload", value: Fmt.speed(stats.uploadSpeed))
            }

            // Ping row
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Text("WAN Ping")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if let ping = stats.pingMs {
                        Text(String(format: "%.0f ms", ping))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(pingColor(ping))
                    } else {
                        Text("—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if stats.routerIP != "—" {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 2) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 9))
                                .foregroundStyle(.cyan)
                            Text("Router Ping")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let ping = stats.routerPingMs {
                            Text(String(format: "%.0f ms", ping))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(pingColor(ping))
                        } else {
                            Text("—")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Totals row
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(Fmt.totalBytes(stats.totalBytesDownloaded))
                        .font(.system(size: 11, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Up")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(Fmt.totalBytes(stats.totalBytesUploaded))
                        .font(.system(size: 11, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Bandwidth chart
            if !downloadHistory.isEmpty || !uploadHistory.isEmpty {
                bandwidthChart
            }

            Divider()

            // Active interfaces
            if stats.interfaces.count > 1 {
                Text("Active Interfaces")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                ForEach(stats.interfaces) { iface in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(iface.name)
                                .font(.system(size: 11, weight: .medium))
                            Text("(\(iface.id))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        addressRow("IPv4", value: iface.ipv4)
                        if iface.ipv6 != "—" {
                            addressRow("IPv6", value: iface.ipv6)
                        }
                        if iface.macAddress != "—" {
                            revealRow("MAC", value: iface.macAddress, revealed: $showMAC)
                        }
                    }
                    .padding(.vertical, 2)
                }
                addressRow("Router", value: stats.routerIP)
            } else {
                // Single interface — original layout
                VStack(alignment: .leading, spacing: 4) {
                    addressRow("Interface", value: stats.interfaceName)
                    addressRow("IPv4 (LAN)", value: stats.lanAddress)
                    addressRow("Router", value: stats.routerIP)
                    addressRow("IPv6", value: stats.ipv6Address)
                    if stats.macAddress != "—" {
                        revealRow("MAC", value: stats.macAddress, revealed: $showMAC)
                    }
                }
            }

            // Addresses (shared section)
            VStack(alignment: .leading, spacing: 4) {

                // WAN IP — hidden by default, click to reveal
                HStack {
                    Text("WAN IP")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if loadingWAN {
                        ProgressView()
                            .controlSize(.small)
                    } else if showWAN, let ip = wanIP {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ip, forType: .string)
                        } label: {
                            HStack(spacing: 3) {
                                Text(ip)
                                    .font(.system(size: 11, design: .monospaced))
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy")
                    } else {
                        Button {
                            fetchWANIP()
                        } label: {
                            Text("Tap to reveal")
                                .font(.system(size: 10))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if stats.isVPNActive {
                    Divider()
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text("VPN Active")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    revealRow("VPN IP", value: stats.vpnAddress, revealed: $showVPNIP)
                    addressRow("VPN Interface", value: stats.vpnInterface)
                }
            }

            // Feature B — Traceroute / MTR (self-contained section)
            if let traceStart, let traceStop, let tracePoll {
                Divider()
                TracerouteSection(
                    defaultHost: tracerouteDefaultHost,
                    start: traceStart,
                    stop: traceStop,
                    poll: tracePoll
                )
            }

            // Speed Test (self-contained block — see SpeedTestSection below)
            Divider()
            SpeedTestSection()
        }
        .padding(12)
        .frame(width: 260)
    }

    /// Default traceroute target: the user's WAN ping target if known, else the router.
    private var tracerouteDefaultHost: String {
        if stats.pingMs != nil, stats.routerIP != "—" { return stats.routerIP }
        if stats.routerIP != "—" { return stats.routerIP }
        return "1.1.1.1"
    }

    private var bandwidthChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bandwidth over time")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(Array(downloadHistory.enumerated()), id: \.offset) { i, val in
                    AreaMark(x: .value("T", i), yStart: .value("Baseline", 0), yEnd: .value("Speed", val), series: .value("Type", "Down"))
                        .foregroundStyle(.green.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("T", i), y: .value("Speed", val), series: .value("Type", "Down"))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                ForEach(Array(uploadHistory.enumerated()), id: \.offset) { i, val in
                    AreaMark(x: .value("T", i), yStart: .value("Baseline", 0), yEnd: .value("Speed", val), series: .value("Type", "Up"))
                        .foregroundStyle(.blue.opacity(0.12))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("T", i), y: .value("Speed", val), series: .value("Type", "Up"))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Fmt.chartSpeed(v))
                                .font(.system(size: 7))
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2]))
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(height: 80)

            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text("Down").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Circle().fill(.blue).frame(width: 5, height: 5)
                    Text("Up").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func revealRow(_ label: String, value: String, revealed: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if revealed.wrappedValue {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    HStack(spacing: 3) {
                        Text(value)
                            .font(.system(size: 11, design: .monospaced))
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to copy")
            } else {
                Button {
                    revealed.wrappedValue = true
                } label: {
                    Text("Tap to reveal")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addressRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                HStack(spacing: 3) {
                    Text(value)
                        .font(.system(size: 11, design: .monospaced))
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help("Click to copy")
        }
    }

    private func netStatColumn(icon: String, iconColor: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pingColor(_ ms: Double) -> Color {
        if ms < 30 { return .green }
        if ms < 80 { return .yellow }
        if ms < 150 { return .orange }
        return .red
    }

    private func fetchWANIP() {
        loadingWAN = true
        Task {
            do {
                guard let url = URL(string: "https://api.ipify.org") else { return }
                let (data, _) = try await URLSession.shared.data(from: url)
                let ip = String(data: data, encoding: .utf8) ?? "—"
                await MainActor.run {
                    wanIP = ip
                    showWAN = true
                    loadingWAN = false
                }
            } catch {
                await MainActor.run {
                    wanIP = "Unavailable"
                    showWAN = true
                    loadingWAN = false
                }
            }
        }
    }
}

// MARK: - Traceroute / MTR Section (Feature B)
//
// Self-contained subview: an expandable host field + Start/Stop and a live
// per-hop table. Kept in its own type so it merges cleanly alongside other
// edits to NetworkDetailPanel.
private struct TracerouteSection: View {
    let defaultHost: String
    let start: (String) async -> Void
    let stop: () async -> Void
    let poll: () async -> (hops: [HelperTraceHop], running: Bool)

    @State private var expanded = false
    // Target is configured in Settings (hover panels can't take keyboard focus, so an
    // inline text field couldn't be typed into). Falls back to the ping target/router.
    @AppStorage("tracerouteTarget") private var tracerouteTarget: String = ""
    @State private var running = false
    @State private var hops: [HelperTraceHop] = []
    @State private var pollTimer: Timer?

    private var effectiveHost: String {
        let t = tracerouteTarget.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? defaultHost : t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Collapsible header
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 9))
                        .foregroundStyle(.purple)
                    Text("Traceroute / MTR")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    if running {
                        Circle().fill(.green).frame(width: 5, height: 5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                // Target (set in Settings → Network) + controls
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(effectiveHost.isEmpty ? "Set target in Settings" : effectiveHost)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(effectiveHost.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if running {
                        Button("Stop") { stopTrace() }
                            .controlSize(.small)
                            .tint(.red)
                    } else {
                        Button("Start") { startTrace() }
                            .controlSize(.small)
                            .disabled(effectiveHost.isEmpty)
                    }
                }

                if !hops.isEmpty {
                    hopTable
                } else if running {
                    Text("Probing…")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear {
            // Don't leave a session or timer running when the panel closes.
            stopTrace()
        }
    }

    private var hopTable: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Header row
            HStack(spacing: 4) {
                Text("#").frame(width: 14, alignment: .trailing)
                Text("Host").frame(maxWidth: .infinity, alignment: .leading)
                Text("Loss").frame(width: 34, alignment: .trailing)
                Text("Last").frame(width: 38, alignment: .trailing)
                Text("Avg").frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.tertiary)

            ForEach(hops, id: \.hop) { hop in
                HStack(spacing: 4) {
                    Text("\(hop.hop)")
                        .frame(width: 14, alignment: .trailing)
                        .foregroundStyle(.tertiary)
                    Text(hop.host)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(format: "%.0f%%", hop.lossPct))
                        .frame(width: 34, alignment: .trailing)
                        .foregroundStyle(lossColor(hop.lossPct))
                    Text(msText(hop.lastMs))
                        .frame(width: 38, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(msText(hop.avgMs))
                        .frame(width: 38, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 9, design: .monospaced))
            }
        }
    }

    private func startTrace() {
        let target = effectiveHost.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        running = true
        hops = []
        Task { await start(target) }
        scheduleTimer()
    }

    private func stopTrace() {
        guard running || pollTimer != nil else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        running = false
        Task { await stop() }
    }

    private func scheduleTimer() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let snap = await poll()
                hops = snap.hops
                running = snap.running
            }
        }
        pollTimer = timer
    }

    private func lossColor(_ pct: Double) -> Color {
        if pct <= 0 { return .green }
        if pct < 20 { return .orange }
        return .red
    }

    private func msText(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return String(format: "%.0f", ms)
    }
}

// MARK: - Speed Test Section (self-contained — added for the network throughput test feature)

/// Expandable "Speed Test" section: runs a multi-gig throughput test via
/// `SpeedTester`, shows live progress, the last result, and an optional
/// auto-run timer with a small sparkline of recent results.
///
/// Fully self-contained so it merges cleanly alongside other panel additions.
struct SpeedTestSection: View {
    @StateObject private var tester = SpeedTester()
    @State private var expanded = false
    @State private var autoRun = false
    @State private var intervalMinutes = 15
    @State private var autoTimer: Timer?

    // Server selection (persisted): Cloudflare by default, or a self-hosted
    // OpenSpeedTest server on the LAN.
    @AppStorage("speedTestUseOpenSpeedTest") private var useOpenSpeedTest = false
    @AppStorage("speedTestOpenSpeedTestURL") private var openSpeedTestURL = ""

    private let intervalOptions = [5, 15, 30, 60]

    /// The configured target server.
    private var selectedServer: SpeedTestServer {
        useOpenSpeedTest ? .openSpeedTest(baseURL: openSpeedTestURL) : .cloudflare
    }

    /// True when a LAN server is selected but no usable URL has been entered.
    private var needsServerURL: Bool {
        useOpenSpeedTest && selectedServer.openSpeedTestBase == nil
    }

    /// Apply the chosen server and start a run.
    private func runTest() {
        tester.server = selectedServer
        tester.start()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header (tap to expand/collapse)
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                    Text("Speed Test")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    if let last = tester.lastResult, !expanded {
                        Text(Fmt.throughput(last.downMbps))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                content
            }
        }
        .onDisappear { stopAutoTimer() }
    }

    @ViewBuilder
    private var content: some View {
        // Server selector: Cloudflare or a self-hosted OpenSpeedTest server.
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Picker("", selection: $useOpenSpeedTest) {
                Text("Cloudflare").tag(false)
                Text("OpenSpeedTest (LAN)").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.system(size: 10))
            Spacer()
        }

        if useOpenSpeedTest && selectedServer.openSpeedTestBase != nil {
            Text(openSpeedTestURL)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }

        // Run / Cancel control
        HStack {
            if tester.isRunning {
                Button {
                    tester.cancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                Spacer()
                ProgressView().controlSize(.small)
            } else {
                Button {
                    runTest()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text("Run Test").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(needsServerURL ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .disabled(needsServerURL)
                if needsServerURL {
                    Text("Set server URL in Settings")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }

        // Phase + live throughput
        liveStatus

        // Last result (down / up)
        if let last = tester.lastResult {
            HStack(spacing: 0) {
                resultColumn(icon: "arrow.down", color: .green, label: "Download", mbps: last.downMbps)
                resultColumn(icon: "arrow.up", color: .blue, label: "Upload", mbps: last.upMbps)
            }
        }

        // Sparkline of recent download results
        if tester.history.count > 1 {
            sparkline
        }

        // Auto-run controls
        Toggle(isOn: Binding(get: { autoRun }, set: { setAutoRun($0) })) {
            Text("Auto-run every")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)

        if autoRun {
            Picker("", selection: Binding(get: { intervalMinutes }, set: { setInterval($0) })) {
                ForEach(intervalOptions, id: \.self) { m in
                    Text("\(m) min").tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.system(size: 10))
        }
    }

    @ViewBuilder
    private var liveStatus: some View {
        switch tester.phase {
        case .idle:
            EmptyView()
        case .download:
            phaseRow(text: "Download…", color: .green, mbps: tester.liveMbps)
        case .upload:
            phaseRow(text: "Upload…", color: .blue, mbps: tester.liveMbps)
        case .done:
            EmptyView()
        case .failed(let message):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func phaseRow(text: String, color: Color, mbps: Double) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Spacer()
            Text(Fmt.throughput(mbps))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }

    private func resultColumn(icon: String, color: Color, label: String, mbps: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(Fmt.throughput(mbps))
                .font(.system(size: 11, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent (download)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(Array(tester.history.enumerated()), id: \.element.id) { i, r in
                    LineMark(x: .value("N", i), y: .value("Mbps", r.downMbps))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("N", i), y: .value("Mbps", r.downMbps))
                        .foregroundStyle(.green)
                        .symbolSize(8)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Fmt.throughput(v))
                                .font(.system(size: 7))
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2]))
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(height: 44)
        }
    }

    // MARK: Auto-run timer

    private func setAutoRun(_ on: Bool) {
        autoRun = on
        if on {
            startAutoTimer()
        } else {
            stopAutoTimer()
        }
    }

    private func setInterval(_ minutes: Int) {
        intervalMinutes = minutes
        if autoRun { startAutoTimer() }
    }

    private func startAutoTimer() {
        stopAutoTimer()
        if !tester.isRunning { runTest() }
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalMinutes * 60), repeats: true) { _ in
            Task { @MainActor in
                if !tester.isRunning { runTest() }
            }
        }
        autoTimer = timer
    }

    private func stopAutoTimer() {
        autoTimer?.invalidate()
        autoTimer = nil
    }
}
