import SwiftUI
import Charts
import MapKit

struct NetworkDetailPanel: View {
    let stats: NetworkStats
    let downloadHistory: [Double]
    let uploadHistory: [Double]
    /// Persistent tester injected by the app so speed-test results survive the panel
    /// being dismissed and reopened.
    @ObservedObject var speedTester: SpeedTester

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
            SpeedTestSection(tester: speedTester, isExpensiveNetwork: stats.isExpensive || stats.isConstrained)
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

    @AppStorage("traceExpanded") private var expanded = false
    // Target is configured in Settings (hover panels can't take keyboard focus, so an
    // inline text field couldn't be typed into). Falls back to the ping target/router.
    @AppStorage("tracerouteTarget") private var tracerouteTarget: String = ""
    @State private var running = false
    @State private var hops: [HelperTraceHop] = []
    @State private var pollTimer: Timer?
    @AppStorage("traceMapShown") private var showMap = false

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

                    // Map disclosure — plots the hops by geolocation.
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showMap.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showMap ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8))
                            Image(systemName: "map")
                                .font(.system(size: 9))
                                .foregroundStyle(.purple)
                            Text("Map")
                                .font(.system(size: 10, weight: .medium))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showMap {
                        TracerouteMapView(hops: hops)
                    }
                } else if running {
                    Text("Probing…")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { restoreFromSession() }
        .onDisappear {
            // Keep the traceroute session itself running; only pause the UI poll timer
            // so the user can reopen the panel later and see live values again.
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Re-sync the running state and hops from the persistent traceroute session when
    /// the panel reappears, resuming the poll timer if a session is still active.
    private func restoreFromSession() {
        Task {
            let snap = await poll()
            running = snap.running
            hops = snap.hops
            if snap.running { scheduleTimer() }
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
    /// Injected so results/history persist across panel dismiss/reopen.
    @ObservedObject var tester: SpeedTester
    /// True when the current network is metered (expensive/constrained); blocks
    /// only the automated interval run, never a manual one.
    var isExpensiveNetwork: Bool = false

    @AppStorage("netSpeedExpanded") private var expanded = false

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
        .onAppear { syncTester() }
        .onChange(of: useOpenSpeedTest) { _, _ in syncTester() }
        .onChange(of: openSpeedTestURL) { _, _ in syncTester() }
        .onChange(of: isExpensiveNetwork) { _, _ in tester.autoRunBlocked = isExpensiveNetwork }
    }

    /// Keep the persistent tester's server + metered-network guard in sync with the UI.
    private func syncTester() {
        tester.server = selectedServer
        tester.autoRunBlocked = isExpensiveNetwork
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

        // Sparkline of recent up/down results
        if tester.history.count > 1 {
            sparkline
        }

        // Auto-run controls
        Toggle("Auto-run on interval", isOn: $tester.autoRun)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 10))

        if tester.autoRun {
            Picker("", selection: $tester.intervalMinutes) {
                ForEach(intervalOptions, id: \.self) { m in
                    Text("every \(m) min").tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.system(size: 10))

            if isExpensiveNetwork {
                Text("Paused — this network is metered. Manual runs still work.")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
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
            HStack(spacing: 10) {
                legendDot(.green, "Down")
                legendDot(.blue, "Up")
            }
            Chart {
                ForEach(Array(tester.history.enumerated()), id: \.element.id) { i, r in
                    LineMark(x: .value("N", i), y: .value("Mbps", r.downMbps), series: .value("Dir", "Down"))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("N", i), y: .value("Mbps", r.upMbps), series: .value("Dir", "Up"))
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

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Traceroute Geolocation Map

/// A geolocated hop for the map.
struct GeoHop: Identifiable, Equatable {
    let id: Int               // hop number
    let ip: String
    let coordinate: CLLocationCoordinate2D
    let label: String         // "City, Country" (or the IP)

    static func == (a: GeoHop, b: GeoHop) -> Bool {
        a.id == b.id && a.ip == b.ip &&
        a.coordinate.latitude == b.coordinate.latitude &&
        a.coordinate.longitude == b.coordinate.longitude
    }
}

/// Caches reverse-IP geolocation lookups (ipwho.is, free HTTPS, no key). Works in the
/// App Store sandbox — only outbound URLSession, no helper required.
actor GeoIPLookup {
    static let shared = GeoIPLookup()
    private var cache: [String: CLLocationCoordinate2D?] = [:]
    private var labels: [String: String] = [:]

    func locate(_ ip: String) async -> (coord: CLLocationCoordinate2D, label: String)? {
        if let cached = cache[ip] {
            guard let c = cached else { return nil }
            return (c, labels[ip] ?? ip)
        }
        guard Self.isPublicIPv4(ip), let url = URL(string: "https://ipwho.is/\(ip)") else {
            cache[ip] = .some(nil); return nil
        }
        struct Resp: Decodable { let success: Bool?; let latitude: Double?; let longitude: Double?; let city: String?; let country: String? }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let r = try JSONDecoder().decode(Resp.self, from: data)
            if r.success == true, let lat = r.latitude, let lon = r.longitude {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let label = [r.city, r.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                cache[ip] = .some(coord)
                labels[ip] = label.isEmpty ? ip : label
                return (coord, labels[ip]!)
            }
        } catch {}
        cache[ip] = .some(nil)
        return nil
    }

    /// Skip private / reserved / non-routable addresses (no public geolocation).
    static func isPublicIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let (a, b) = (parts[0], parts[1])
        if a == 10 || a == 127 || a == 0 { return false }
        if a == 172, (16...31).contains(b) { return false }
        if a == 192, b == 168 { return false }
        if a == 169, b == 254 { return false }
        if a == 100, (64...127).contains(b) { return false }     // CGNAT
        if a >= 224 { return false }                              // multicast/reserved
        return true
    }
}

/// Shows the located traceroute hops on a map, revealing them one-by-one with the
/// route line so the user can watch the path travel.
struct TracerouteMapView: View {
    let hops: [HelperTraceHop]

    @State private var geoHops: [GeoHop] = []
    @State private var revealCount = 0
    @State private var camera: MapCameraPosition = .automatic

    private var revealed: [GeoHop] { Array(geoHops.prefix(revealCount)) }
    private var hopsKey: String { hops.map { "\($0.hop):\($0.host)" }.joined(separator: ",") }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if revealed.count > 1 {
                    MapPolyline(coordinates: revealed.map { $0.coordinate })
                        .stroke(.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ForEach(revealed) { h in
                    Annotation(h.label, coordinate: h.coordinate) {
                        ZStack {
                            Circle().fill(.purple).frame(width: 14, height: 14)
                            Circle().stroke(.white, lineWidth: 1.5).frame(width: 14, height: 14)
                            Text("\(h.id)").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if geoHops.isEmpty {
                Text("Locating hops…")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(6)
            } else if let last = revealed.last {
                Text("\(last.label)")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }
        }
        .task(id: hopsKey) { await geolocate() }
    }

    private func geolocate() async {
        var result: [GeoHop] = []
        for hop in hops where hop.host != "*" {
            if let g = await GeoIPLookup.shared.locate(hop.host) {
                result.append(GeoHop(id: hop.hop, ip: hop.host, coordinate: g.coord, label: g.label))
            }
        }
        if result != geoHops { geoHops = result }
        await revealRoute()
    }

    /// Reveal hops one at a time so the route visibly travels across the map. Runs in
    /// the view's `.task`, so it cancels automatically when the panel/section goes away.
    private func revealRoute() async {
        revealCount = min(1, geoHops.count)
        camera = .automatic
        while revealCount < geoHops.count {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                revealCount += 1
                camera = .automatic
            }
        }
    }
}
