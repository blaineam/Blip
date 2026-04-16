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
