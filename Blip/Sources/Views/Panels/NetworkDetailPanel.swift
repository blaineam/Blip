import SwiftUI
import Charts

struct NetworkDetailPanel: View {
    let stats: NetworkStats
    let downloadHistory: [Double]
    let uploadHistory: [Double]

    @State private var wanIP: String? = nil
    @State private var showWAN = false
    @State private var loadingWAN = false

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

            // Speed + Ping
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                        Text("Download")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(Fmt.speed(stats.downloadSpeed))
                        .font(.system(size: 11, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                        Text("Upload")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(Fmt.speed(stats.uploadSpeed))
                        .font(.system(size: 11, design: .monospaced))
                }
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
                if stats.routerIP != "—" {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 2) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 9))
                                .foregroundStyle(.cyan)
                            Text("Router")
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
                }
            }

            // Bandwidth chart
            if !downloadHistory.isEmpty || !uploadHistory.isEmpty {
                bandwidthChart
            }

            Divider()

            // Addresses
            VStack(alignment: .leading, spacing: 4) {
                addressRow("Interface", value: stats.interfaceName)
                addressRow("IPv4 (LAN)", value: stats.lanAddress)
                addressRow("Router", value: stats.routerIP)
                addressRow("IPv6", value: stats.ipv6Address)
                if stats.macAddress != "—" {
                    addressRow("MAC", value: stats.macAddress)
                }

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
                    addressRow("VPN IP", value: stats.vpnAddress)
                    addressRow("VPN Interface", value: stats.vpnInterface)
                }
            }
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
            .chartYAxis(.hidden)
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
