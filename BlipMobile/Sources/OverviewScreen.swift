import SwiftUI

struct OverviewScreen: View {
    @ObservedObject var stats: DeviceStats

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    cpuCard
                    storageCard
                    batteryCard
                    thermalCard
                    memoryCard
                    networkCard
                    systemCard
                }
                .padding()
                detailsSection
                    .padding(.horizontal)
                    .padding(.bottom, 24)
            }
            .navigationTitle("Blip")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { AboutScreen() } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable { stats.sample() }
        }
    }

    private var s: DeviceSnapshot { stats.snapshot }

    private var cpuCard: some View {
        StatCard(icon: "cpu", tint: .blue, title: "CPU") {
            Text("\(Int(s.cpuUsagePercent))%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Sparkline(values: stats.cpuHistory.values, tint: .blue, fixedDomain: 0...100)
        }
    }

    private var storageCard: some View {
        StatCard(icon: "internaldrive", tint: .orange, title: "Storage") {
            Gauge(value: s.storagePercentUsed, in: 0...100) { EmptyView() } currentValueLabel: {
                Text("\(Int(s.storagePercentUsed))%")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(s.storagePercentUsed > 90 ? .red : .orange)
            Text("\(Fmt.bytes(s.storageFree)) free of \(Fmt.bytes(s.storageTotal))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var batteryCard: some View {
        StatCard(icon: batteryIcon, tint: .green, title: "Battery") {
            if let level = s.batteryLevel {
                Text("\(Int(level * 100))%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
            } else {
                Text("—").font(.system(size: 28, weight: .bold, design: .rounded))
            }
            Text(s.lowPowerMode ? "\(s.batteryState) · Low Power" : s.batteryState)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var thermalCard: some View {
        StatCard(icon: "thermometer.medium", tint: thermalTint, title: "Thermal") {
            Text(s.thermalLabel)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(thermalTint)
            Text("System thermal state")
                .font(.caption2).foregroundStyle(.secondary)
            if stats.thermalHistory.values.count > 2 {
                ThermalSteps(values: stats.thermalHistory.values, height: 24)
            }
        }
    }

    private var memoryCard: some View {
        StatCard(icon: "memorychip", tint: .blue, title: "Memory") {
            Text(Fmt.bytes(Int64(s.memoryPhysical)))
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(s.memoryAppAvailable > 0
                 ? "\(Fmt.bytes(Int64(s.memoryAppAvailable))) available to apps"
                 : "Physical memory")
                .font(.caption2).foregroundStyle(.secondary)
            if stats.memoryHistory.values.count > 2 {
                Sparkline(values: stats.memoryHistory.values, tint: .blue, height: 24)
            }
        }
    }

    private var networkCard: some View {
        StatCard(icon: networkIcon, tint: .teal, title: "Network") {
            Text(s.interfaceType)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(pathNote)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var systemCard: some View {
        StatCard(icon: "iphone.gen3", tint: .purple, title: "Device") {
            Text(s.model)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("Up \(Fmt.uptime(s.uptime))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The "as many stats as possible" section — every row a public API tells the truth about.
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Details").font(.headline).padding(.bottom, 2)
            detailRow("Memory free", Fmt.bytes(Int64(s.memFree)))
            detailRow("Memory active", Fmt.bytes(Int64(s.memActive)))
            detailRow("Memory wired", Fmt.bytes(Int64(s.memWired)))
            detailRow("Memory compressed", Fmt.bytes(Int64(s.memCompressed)))
            detailRow("This app's footprint", Fmt.bytes(Int64(s.appFootprint)))
            detailRow("Load average", String(format: "%.2f · %.2f · %.2f", s.load1, s.load5, s.load15))
            detailRow("Cores", s.coresPerformance > 0
                      ? "\(s.coresTotal) (\(s.coresPerformance)P + \(s.coresEfficiency)E)"
                      : "\(s.coresTotal)")
            if let boot = s.bootDate {
                detailRow("Booted", boot.formatted(date: .abbreviated, time: .shortened))
            }
            detailRow("Storage (if caches purge)", Fmt.bytes(s.storageOpportunistic))
            if let radio = s.radioTech { detailRow("Radio", radio) }
            ForEach(s.localIPs, id: \.self) { ip in
                detailRow("IP", ip)
            }
            detailRow("OS", s.osVersion)
        }
    }

    private func detailRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.weight(.medium)).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var batteryIcon: String {
        guard let level = s.batteryLevel else { return "battery.100" }
        if s.batteryState == "Charging" { return "battery.100.bolt" }
        if level < 0.2 { return "battery.25" }
        if level < 0.6 { return "battery.50" }
        return "battery.100"
    }

    private var thermalTint: Color {
        switch s.thermalState {
        case 0: return .green
        case 1: return .yellow
        case 2: return .orange
        default: return .red
        }
    }

    private var networkIcon: String {
        switch s.interfaceType {
        case "Wi-Fi": return "wifi"
        case "Cellular": return "antenna.radiowaves.left.and.right"
        case "Wired": return "cable.connector"
        case "Offline": return "wifi.slash"
        default: return "network"
        }
    }

    private var pathNote: String {
        var notes: [String] = []
        if s.isExpensivePath { notes.append("metered") }
        if s.isConstrainedPath { notes.append("low data mode") }
        return notes.isEmpty ? "Current route" : notes.joined(separator: " · ")
    }
}

struct StatCard<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func uptime(_ t: TimeInterval) -> String {
        let days = Int(t) / 86400, hours = (Int(t) % 86400) / 3600, mins = (Int(t) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}
