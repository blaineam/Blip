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
    var onOpenTracerouteWindow: (() -> Void)? = nil

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

            // Feature B — Traceroute / MTR (self-contained section).
            // Helper-only — hidden in screenshots so they show only base features.
            if !BlipScreenshotMode.isActive, let traceStart, let traceStop, let tracePoll {
                Divider()
                TracerouteSection(
                    defaultHost: tracerouteDefaultHost,
                    start: traceStart,
                    stop: traceStop,
                    poll: tracePoll,
                    onOpenWindow: onOpenTracerouteWindow
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
    var onOpenWindow: (() -> Void)? = nil

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
                    if onOpenWindow != nil {
                        Image(systemName: "macwindow")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .onTapGesture { onOpenWindow?() }
                            .help("Open in a window")
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
    // Auto-run is persisted here (UI source of truth) and pushed to the tester so the
    // switch always reflects the real state after the panel is dismissed/reopened.
    @AppStorage("netSpeedAutoRun") private var autoRunPref = false
    @AppStorage("netSpeedInterval") private var intervalPref = 15

    // Server selection (persisted): Cloudflare (default), OVH, Hetzner, or a
    // self-hosted OpenSpeedTest server on the LAN. The test only ever contacts the
    // server chosen here — there is no automatic fallback to any other host.
    @AppStorage("speedTestServerKind") private var serverKind = "cloudflare"
    @AppStorage("speedTestOpenSpeedTestURL") private var openSpeedTestURL = ""

    private let intervalOptions = [1, 5, 15, 30, 60]

    /// The configured target server.
    private var selectedServer: SpeedTestServer {
        switch serverKind {
        case "ovh": return .ovh
        case "hetzner": return .hetzner
        case "openspeedtest": return .openSpeedTest(baseURL: openSpeedTestURL)
        default: return .cloudflare
        }
    }

    /// True when the LAN server is selected but no usable URL has been entered.
    private var needsServerURL: Bool {
        serverKind == "openspeedtest" && selectedServer.openSpeedTestBase == nil
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
        .onChange(of: serverKind) { _, _ in syncTester() }
        .onChange(of: openSpeedTestURL) { _, _ in syncTester() }
        .onChange(of: isExpensiveNetwork) { _, _ in tester.autoRunBlocked = isExpensiveNetwork }
    }

    /// Keep the persistent tester's server + metered-network guard in sync with the UI.
    private func syncTester() {
        tester.server = selectedServer
        tester.autoRunBlocked = isExpensiveNetwork
        if tester.autoRun != autoRunPref { tester.autoRun = autoRunPref }
        if tester.intervalMinutes != intervalPref { tester.intervalMinutes = intervalPref }
    }

    @ViewBuilder
    private var content: some View {
        // Server selector: Cloudflare, OVH, Hetzner, or a self-hosted OpenSpeedTest server.
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Picker("", selection: $serverKind) {
                Text("Cloudflare").tag("cloudflare")
                Text("OVH (download only)").tag("ovh")
                Text("Hetzner (download only)").tag("hetzner")
                Text("OpenSpeedTest (LAN)").tag("openspeedtest")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.system(size: 10))
            Spacer()
        }

        if serverKind == "openspeedtest" && selectedServer.openSpeedTestBase != nil {
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

        // Last result (down / up). Upload shows "—" for download-only servers.
        if let last = tester.lastResult {
            HStack(spacing: 0) {
                resultColumn(icon: "arrow.down", color: .green, label: "Download", mbps: last.downMbps)
                resultColumn(icon: "arrow.up", color: .blue, label: "Upload", mbps: last.upMbps)
            }
        }

        // Sparkline of recent up/down results
        if !tester.history.isEmpty {
            sparkline
        }

        // Auto-run controls
        BlipToggle(title: "Auto-run on interval", isOn: $autoRunPref) { v in tester.autoRun = v }

        if autoRunPref {
            Picker("", selection: $intervalPref) {
                ForEach(intervalOptions, id: \.self) { m in
                    Text("every \(m) min").tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.system(size: 10))
            .onChange(of: intervalPref) { _, v in tester.intervalMinutes = v }

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

    private func resultColumn(icon: String, color: Color, label: String, mbps: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(mbps.map(Fmt.throughput) ?? "—")
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
                    // Point marks make individual results visible — including the very
                    // first one, where a single-sample line would otherwise draw nothing.
                    PointMark(x: .value("N", i), y: .value("Mbps", r.downMbps))
                        .foregroundStyle(.green)
                        .symbolSize(18)
                    // Upload series only for results that measured it (skips OVH/Hetzner).
                    if let up = r.upMbps {
                        LineMark(x: .value("N", i), y: .value("Mbps", up), series: .value("Dir", "Up"))
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("N", i), y: .value("Mbps", up))
                            .foregroundStyle(.blue)
                            .symbolSize(18)
                    }
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

/// IP-address classification used to skip hops that can't be publicly geolocated.
/// Geolocation itself is done entirely on-device via `GeoIPDatabase` (no network
/// lookup, no third-party service).
enum GeoIPLookup {
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
    var height: CGFloat = 170

    @State private var geoHops: [GeoHop] = []
    @State private var camera: MapCameraPosition = .automatic
    /// True once we've framed the route. We frame exactly once and then never move the
    /// camera again, so the user can pan/zoom freely and it never lurches or hits (0,0).
    @State private var didFrame = false
    /// On-device geolocation database (optional, user-downloaded from Settings).
    @ObservedObject private var geoDB = GeoIPDatabase.shared

    private var hopsKey: String { hops.map { "\($0.hop):\($0.host)" }.joined(separator: ",") }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if didFrame {
                    Map(position: $camera, interactionModes: [.pan, .zoom]) {
                        if geoHops.count > 1 {
                            MapPolyline(coordinates: geoHops.map { $0.coordinate })
                                .stroke(.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                        ForEach(geoHops) { h in
                            Annotation(h.label, coordinate: h.coordinate) {
                                ZStack {
                                    Circle().fill(.purple).frame(width: 14, height: 14)
                                    Circle().stroke(.white, lineWidth: 1.5).frame(width: 14, height: 14)
                                    Text("\(h.id)").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    .mapStyle(.standard(elevation: .flat))
                } else if !geoDB.isReady {
                    // No offline database installed — the map does no network geolocation,
                    // so prompt the user to download the optional database from Settings.
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay(
                            VStack(spacing: 5) {
                                Image(systemName: "globe.badge.chevron.backward")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                                Text("Download the offline location database in\nSettings → Network to map the route.")
                                    .font(.system(size: 9))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                        )
                } else {
                    // Placeholder while locating — avoids showing the default world view (0,0).
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay(
                            VStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("Locating hops on the map…")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        )
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if didFrame, let last = geoHops.last {
                Text("\(last.label)")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }
        }
        .task(id: "\(hopsKey)|\(geoDB.isReady)") { await geolocate() }
    }

    /// Geolocate the current hops, then frame the route **once** and leave the camera
    /// alone. The map only appears after it's framed (so there's no (0,0) flash), and it
    /// never re-zooms as the live traceroute refines — the user pans/zooms freely.
    private func geolocate() async {
        // No database installed → nothing to plot (and the prompt placeholder shows).
        guard geoDB.isReady else {
            geoHops = []
            didFrame = false
            return
        }
        var built: [GeoHop] = []
        for hop in hops where hop.host != "*" {
            if Task.isCancelled { return }
            // Skip private/reserved IPv4 (no public geolocation); IPv6 is looked up directly.
            if !hop.host.contains(":") && !GeoIPLookup.isPublicIPv4(hop.host) { continue }
            guard let g = geoDB.lookup(hop.host) else { continue }
            // Skip null-island / invalid coordinates so they can't drag the map to 0,0.
            if abs(g.latitude) < 0.01 && abs(g.longitude) < 0.01 { continue }
            let label = [g.city, g.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            built.append(GeoHop(
                id: hop.hop, ip: hop.host,
                coordinate: CLLocationCoordinate2D(latitude: g.latitude, longitude: g.longitude),
                label: label.isEmpty ? hop.host : label))
        }
        if Task.isCancelled { return }
        guard built != geoHops else { return }

        if built.isEmpty {
            // The route was cleared (a new traceroute is starting) — re-arm the one-time
            // framing for the next route. This is the ONLY thing that re-enables framing.
            geoHops = []
            didFrame = false
            return
        }

        geoHops = built
        if !didFrame {
            // Frame exactly once, before the map is revealed. After this the camera is
            // never touched again — the user pans/zooms and stays fully in control, even
            // as the live traceroute keeps refining hops.
            camera = .region(Self.region(for: built))
            didFrame = true
        }
    }

    /// A region centered on the bulk of the hops, zoomed out. Uses a circular mean for
    /// longitude (so a route crossing the antimeridian doesn't average into the Atlantic)
    /// and drops far outliers — e.g. an anycast destination like 1.1.1.1 that geolocates
    /// to the wrong continent — so they can't drag the frame into the ocean off Africa.
    private static func region(for hops: [GeoHop]) -> MKCoordinateRegion {
        guard !hops.isEmpty else { return MKCoordinateRegion(.world) }
        let initial = meanCenter(hops)
        var core = hops.filter {
            abs($0.coordinate.latitude - initial.latitude) <= 45
                && abs(lonDiff($0.coordinate.longitude, initial.longitude)) <= 60
        }
        if core.isEmpty { core = hops }

        let center = meanCenter(core)
        let lats = core.map(\.coordinate.latitude)
        let latSpread = (lats.max() ?? center.latitude) - (lats.min() ?? center.latitude)
        let lonSpread = (core.map { abs(lonDiff($0.coordinate.longitude, center.longitude)) }.max() ?? 0) * 2
        let span = MKCoordinateSpan(
            latitudeDelta: min(120, max(8, latSpread * 1.6)),
            longitudeDelta: min(160, max(8, lonSpread * 1.6))
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Mean coordinate with a circular mean for longitude (antimeridian-safe).
    private static func meanCenter(_ hops: [GeoHop]) -> CLLocationCoordinate2D {
        let lat = hops.map(\.coordinate.latitude).reduce(0, +) / Double(hops.count)
        let lonRad = hops.map { $0.coordinate.longitude * .pi / 180 }
        let x = lonRad.map(cos).reduce(0, +)
        let y = lonRad.map(sin).reduce(0, +)
        let lon = (abs(x) < 1e-9 && abs(y) < 1e-9) ? 0 : atan2(y, x) * 180 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Smallest signed longitude difference (−180…180), wrapping the antimeridian.
    private static func lonDiff(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}

// MARK: - Traceroute Window (opens like Settings; shows a Dock icon)

/// A full-window traceroute monitor with a large animated map and a scrollable hop
/// table. Because this is a real key window (unlike the hover panel) the target field
/// is editable here.
struct TracerouteWindowView: View {
    let start: (String) async -> Void
    let stop: () async -> Void
    let poll: () async -> (hops: [HelperTraceHop], running: Bool)

    @AppStorage("tracerouteTarget") private var tracerouteTarget = ""
    @State private var host = ""
    @State private var running = false
    @State private var hops: [HelperTraceHop] = []
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(.purple)
                Text("Traceroute / MTR").font(.headline)
                Spacer()
                TextField("host or IP", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .disableAutocorrection(true)
                    .onSubmit { if !running { startTrace() } }
                if running {
                    Button("Stop") { stopTrace() }.tint(.red)
                } else {
                    Button("Start") { startTrace() }
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            TracerouteMapView(hops: hops, height: 300)

            if !hops.isEmpty {
                hopTable
            } else {
                Spacer()
                Text(running ? "Probing…" : "Enter a host and press Start.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            if host.isEmpty { host = tracerouteTarget.isEmpty ? "1.1.1.1" : tracerouteTarget }
            Task {
                let snap = await poll()
                running = snap.running
                hops = snap.hops
                if snap.running { schedulePoll() }
            }
        }
        .onDisappear { pollTimer?.invalidate(); pollTimer = nil }
    }

    private var hopTable: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("#").frame(width: 22, alignment: .trailing)
                    Text("Host").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Loss").frame(width: 48, alignment: .trailing)
                    Text("Last").frame(width: 56, alignment: .trailing)
                    Text("Avg").frame(width: 56, alignment: .trailing)
                    Text("Best").frame(width: 56, alignment: .trailing)
                    Text("Worst").frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(hops, id: \.hop) { hop in
                    HStack(spacing: 8) {
                        Text("\(hop.hop)").frame(width: 22, alignment: .trailing).foregroundStyle(.tertiary)
                        Text(hop.host).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).truncationMode(.middle)
                        Text(String(format: "%.0f%%", hop.lossPct)).frame(width: 48, alignment: .trailing)
                            .foregroundStyle(hop.lossPct <= 0 ? .green : (hop.lossPct < 20 ? .orange : .red))
                        Text(ms(hop.lastMs)).frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
                        Text(ms(hop.avgMs)).frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
                        Text(ms(hop.bestMs)).frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
                        Text(ms(hop.worstMs)).frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
        .frame(maxHeight: 160)
    }

    private func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }

    private func startTrace() {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        tracerouteTarget = target
        running = true
        hops = []
        Task { await start(target) }
        schedulePoll()
    }

    private func stopTrace() {
        pollTimer?.invalidate(); pollTimer = nil
        running = false
        Task { await stop() }
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let snap = await poll()
                hops = snap.hops
                running = snap.running
            }
        }
    }
}

// MARK: - BlipToggle

/// A pure-SwiftUI switch. SwiftUI's `.switch` toggle style is backed by an AppKit
/// NSSwitch that can render its previous (stale) state when the hosting view is
/// rebuilt — which the detail panels do every couple of seconds. Drawing the switch
/// ourselves guarantees it always reflects the bound value.
struct BlipToggle: View {
    let title: String
    @Binding var isOn: Bool
    var onChange: ((Bool) -> Void)? = nil

    var body: some View {
        Button {
            isOn.toggle()
            onChange?(isOn)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Color.green : Color.gray.opacity(0.35))
                        .frame(width: 26, height: 15)
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .padding(1.5)
                        .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                }
                .animation(.easeInOut(duration: 0.15), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
