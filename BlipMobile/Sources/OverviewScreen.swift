import SwiftUI

// The Overview grid: each card is a summary AND a door — tap for the full detail screen
// (field feedback: details grouped under each tile, not one flat list). The gear opens
// Settings; the doc button exports a one-file snapshot of everything.

struct OverviewScreen: View {
    @ObservedObject var stats: DeviceStats
    @Environment(\.horizontalSizeClass) private var hSize

    /// iPhone portrait (compact width): the classic two-up. iPad / regular width:
    /// adaptive so the grid fills wide canvases (4-up on a 13" iPad).
    /// (.adaptive(minimum: 240) alone collapsed iPhone portrait to ONE column —
    /// 408pt of content can't fit two 240pt minimums. Field-caught.)
    private var columns: [GridItem] {
        hSize == .regular ? [GridItem(.adaptive(minimum: 240), spacing: 12)]
                          : [GridItem(.flexible()), GridItem(.flexible())]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                suggestions
                LazyVGrid(columns: columns, spacing: 12) {
                    card(cpuCard) { CPUDetailScreen(stats: stats) }
                    card(memoryCard) { MemoryDetailScreen(stats: stats) }
                    card(storageCard) { StorageDetailScreen(stats: stats) }
                    card(networkCard) { NetworkDetailScreen(stats: stats) }
                    card(batteryCard) { BatteryDetailScreen(stats: stats) }
                    card(thermalCard) { ThermalDetailScreen(stats: stats) }
                    card(systemCard) { DeviceDetailScreen(stats: stats) }
                }
                .padding()
            }
            .navigationTitle("Blip")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: SnapshotExport.file(for: stats.snapshot, speedHistory: nil),
                              preview: SharePreview("Blip Snapshot", image: Image(systemName: "doc.text"))) {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsScreen() } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable { stats.sample() }
        }
    }

    private func card<D: View>(_ content: some View, @ViewBuilder destination: () -> D) -> some View {
        NavigationLink { destination() } label: { content }
            .buttonStyle(.plain)
    }

    private var s: DeviceSnapshot { stats.snapshot }

    // MARK: - Honest, actionable suggestions (only ever shown when one actually applies)

    @ViewBuilder
    private var suggestions: some View {
        let items = Suggestions.evaluate(s)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.icon).foregroundStyle(item.tint)
                        Text(item.text).font(.footnote)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    // MARK: - Cards

    private var cpuCard: some View {
        StatCard(icon: "cpu", tint: .blue, title: "CPU") {
            Text("\(Int(s.cpuUsagePercent))%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Sparkline(values: stats.cpuHistory.values, tint: .blue, height: 24, fixedDomain: 0...100)
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
            Text(Fmt.memory(Int64(s.memoryPhysical)))
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(s.memoryAppAvailable > 0
                 ? "\(Fmt.memory(Int64(s.memoryAppAvailable))) available to apps"
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
            Text(s.marketingName)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("Up \(Fmt.uptime(s.bootUptime ?? s.uptime))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Icons/tints

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
        if s.vpnActive { notes.append("VPN") }
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
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    /// RAM uses the binary style — 12 GiB reads "12 GB" the way Apple markets it,
    /// not "12.88 GB" (decimal .file style applied to a binary quantity).
    static func memory(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .memory)
    }
    static func uptime(_ t: TimeInterval) -> String {
        let days = Int(t) / 86400, hours = (Int(t) % 86400) / 3600, mins = (Int(t) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

// MARK: - Suggestions (#feedback: "if we can genuinely make useful suggestions, do")
// Every rule keys off a signal iOS actually reports; nothing speculative, nothing scolding.

enum Suggestions {
    struct Item: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let text: String
    }

    static func evaluate(_ s: DeviceSnapshot) -> [Item] {
        var out: [Item] = []
        if s.storagePercentUsed > 92 {
            out.append(.init(id: "storage", icon: "internaldrive", tint: .red,
                             text: "Storage is nearly full (\(Fmt.bytes(s.storageFree)) left). iOS slows down and updates fail below ~1 GB — offload unused apps or large videos in Settings → General → iPhone Storage."))
        }
        if s.thermalState >= 2 {
            out.append(.init(id: "thermal", icon: "thermometer.high", tint: .orange,
                             text: "The device is running \(s.thermalLabel.lowercased()) — performance is being throttled. Take it off the charger or out of the sun; skip benchmarking until nominal."))
        }
        if s.lowPowerMode && s.batteryState == "Charging", let l = s.batteryLevel, l > 0.8 {
            out.append(.init(id: "lpm", icon: "battery.100.bolt", tint: .yellow,
                             text: "Low Power Mode is still on while charging above 80% — background refresh and performance stay reduced until you switch it off."))
        }
        if s.isConstrainedPath {
            out.append(.init(id: "lowdata", icon: "arrow.down.circle", tint: .teal,
                             text: "Low Data Mode is active on this connection — app downloads, quality, and sync are being limited. Intentional? It's per-network in Wi-Fi/Cellular settings."))
        }
        if s.memoryAppAvailable > 0 && s.memoryAppAvailable < 500 << 20 {
            out.append(.init(id: "mem", icon: "memorychip", tint: .blue,
                             text: "Memory available to apps is low (\(Fmt.bytes(Int64(s.memoryAppAvailable)))). Heavy apps may relaunch from scratch; closing camera- and game-class apps you're done with helps."))
        }
        return out
    }
}
