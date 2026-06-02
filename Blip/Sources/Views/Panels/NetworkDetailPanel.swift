import SwiftUI
import Charts

struct NetworkDetailPanel: View {
    let stats: NetworkStats
    let downloadHistory: [Double]
    let uploadHistory: [Double]

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

            // Speed Test (self-contained block — see SpeedTestSection below)
            Divider()
            SpeedTestSection()
        }
        .padding(12)
        .frame(width: 260)
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

    private let intervalOptions = [5, 15, 30, 60]

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
                    tester.start()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text("Run Test").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
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
        if !tester.isRunning { tester.start() }
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalMinutes * 60), repeats: true) { _ in
            Task { @MainActor in
                if !tester.isRunning { tester.start() }
            }
        }
        autoTimer = timer
    }

    private func stopAutoTimer() {
        autoTimer?.invalidate()
        autoTimer = nil
    }
}
