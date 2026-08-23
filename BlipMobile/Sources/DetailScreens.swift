import SwiftUI

// Per-card detail screens — the drill-in layer. Shared grammar: a hero restating the card's
// headline, a session chart where one exists, then rows. Reference-worthy values are
// copyable; anything privacy-adjacent (WAN IP) is reveal-on-tap and never fetched early.

// MARK: - Shared rows

/// A labeled value with a tap-to-copy affordance (#feedback: copy buttons on useful fields).
struct CopyRow: View {
    let name: String
    let value: String
    var monospaced = false
    @State private var copied = false

    var body: some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
            Button {
                UIPasteboard.general.string = value
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.spring(duration: 0.3)) { copied = true }
                Task { try? await Task.sleep(nanoseconds: 1_200_000_000)
                       await MainActor.run { withAnimation { copied = false } } }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
    }
}

struct PlainRow: View {
    let name: String
    let value: String
    var body: some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

// MARK: - CPU

struct CPUDetailScreen: View {
    @ObservedObject var stats: DeviceStats
    private var s: DeviceSnapshot { stats.snapshot }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Int(s.cpuUsagePercent))%")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Sparkline(values: stats.cpuHistory.values, tint: .blue, height: 70, fixedDomain: 0...100)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Total CPU across all cores, sampled every 2 seconds while Blip is open.")
            }
            Section("Load") {
                PlainRow(name: "Load average (1m)", value: String(format: "%.2f", s.load1))
                PlainRow(name: "Load average (5m)", value: String(format: "%.2f", s.load5))
                PlainRow(name: "Load average (15m)", value: String(format: "%.2f", s.load15))
            }
            Section("Cores") {
                PlainRow(name: "Total", value: "\(s.coresTotal)")
                if s.coresPerformance > 0 {
                    PlainRow(name: "Performance", value: "\(s.coresPerformance)")
                    PlainRow(name: "Efficiency", value: "\(s.coresEfficiency)")
                }
            }
        }
        .navigationTitle("CPU")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Memory

struct MemoryDetailScreen: View {
    @ObservedObject var stats: DeviceStats
    private var s: DeviceSnapshot { stats.snapshot }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Fmt.bytes(Int64(s.memoryPhysical)))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    if stats.memoryHistory.values.count > 2 {
                        Sparkline(values: stats.memoryHistory.values, tint: .blue, height: 70)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Chart: memory available to apps this session (os_proc_available_memory).")
            }
            Section("Breakdown") {
                PlainRow(name: "Available to apps", value: Fmt.bytes(Int64(s.memoryAppAvailable)))
                PlainRow(name: "Free", value: Fmt.bytes(Int64(s.memFree)))
                PlainRow(name: "Active", value: Fmt.bytes(Int64(s.memActive)))
                PlainRow(name: "Inactive", value: Fmt.bytes(Int64(s.memInactive)))
                PlainRow(name: "Wired", value: Fmt.bytes(Int64(s.memWired)))
                PlainRow(name: "Compressed", value: Fmt.bytes(Int64(s.memCompressed)))
            }
            Section("This App") {
                PlainRow(name: "Blip's footprint", value: Fmt.bytes(Int64(s.appFootprint)))
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Storage (hosts the disk speed test)

struct StorageDetailScreen: View {
    @ObservedObject var stats: DeviceStats
    @StateObject private var bench = MobileDiskBench()
    private var s: DeviceSnapshot { stats.snapshot }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Gauge(value: s.storagePercentUsed, in: 0...100) { EmptyView() } currentValueLabel: {
                        Text("\(Int(s.storagePercentUsed))%")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(s.storagePercentUsed > 90 ? .red : .orange)
                    Text("\(Fmt.bytes(s.storageFree)) free of \(Fmt.bytes(s.storageTotal))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                PlainRow(name: "Free (strict)", value: Fmt.bytes(s.storageFree))
                PlainRow(name: "Free if caches purge", value: Fmt.bytes(s.storageOpportunistic))
            } footer: {
                Text("iOS can reclaim purgeable caches under pressure — the second number is what important-usage requests could actually get.")
            }
            MobileDiskBenchSection(bench: bench)
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Network

struct NetworkDetailScreen: View {
    @ObservedObject var stats: DeviceStats
    @State private var wanRevealed = false
    private var s: DeviceSnapshot { stats.snapshot }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.interfaceType)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        if s.isExpensivePath { badge("metered", .orange) }
                        if s.isConstrainedPath { badge("low data", .orange) }
                        if s.vpnActive { badge("VPN", .indigo) }
                        if let radio = s.radioTech { badge(radio, .teal) }
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                wanRow
            } header: {
                Text("Public Address")
            } footer: {
                Text("Fetched from api.ipify.org only when you reveal it — checking your public IP necessarily tells that service your public IP, so Blip never does it on its own.")
            }
            Section("Local Addresses") {
                if s.localIPs.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(s.localIPs, id: \.self) { entry in
                        let parts = entry.split(separator: " ", maxSplits: 1).map(String.init)
                        CopyRow(name: parts.first ?? "if",
                                value: parts.count > 1 ? parts[1] : entry,
                                monospaced: true)
                    }
                }
            }
            Section {
                PlainRow(name: "VPN", value: s.vpnActive ? "Active (utun interface up)" : "Not detected")
            } footer: {
                Text("Detected from routing interfaces; a VPN app's own status is authoritative.")
            }
        }
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var wanRow: some View {
        if let wan = stats.wanIP, wanRevealed {
            CopyRow(name: "WAN IP", value: wan, monospaced: true)
        } else {
            Button {
                wanRevealed = true
                stats.revealWANIP()
            } label: {
                HStack {
                    Text("WAN IP").foregroundStyle(.secondary)
                    Spacer()
                    if stats.wanIPLoading { ProgressView().controlSize(.small) }
                    else { Label("Tap to reveal", systemImage: "eye").font(.callout) }
                }
            }
        }
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Battery

struct BatteryDetailScreen: View {
    @ObservedObject var stats: DeviceStats
    private var s: DeviceSnapshot { stats.snapshot }

    var body: some View {
        List {
            Section {
                Text(s.batteryLevel.map { "\(Int($0 * 100))%" } ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .padding(.vertical, 4)
            }
            Section {
                PlainRow(name: "State", value: s.batteryState)
                PlainRow(name: "Low Power Mode", value: s.lowPowerMode ? "On" : "Off")
            } footer: {
                Text("iOS reports level in 1% steps and doesn't expose battery health, cycle count, or wattage to apps — Settings → Battery is the only honest source for those.")
            }
        }
        .navigationTitle("Battery")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Thermal

struct ThermalDetailScreen: View {
    @ObservedObject var stats: DeviceStats
    private var s: DeviceSnapshot { stats.snapshot }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.thermalLabel)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                    if stats.thermalHistory.values.count > 2 {
                        ThermalSteps(values: stats.thermalHistory.values, height: 60)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("The four thermal states are the only temperature signal iOS grants apps — there is no die-temperature API. Serious and Critical mean active throttling.")
            }
            Section("What each state means") {
                PlainRow(name: "Nominal", value: "Full performance")
                PlainRow(name: "Fair", value: "Warm; fans-equivalent measures")
                PlainRow(name: "Serious", value: "Throttling; charging may slow")
                PlainRow(name: "Critical", value: "Heavy throttling; cool it down")
            }
        }
        .navigationTitle("Thermal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tint: Color {
        switch s.thermalState {
        case 0: return .green
        case 1: return .yellow
        case 2: return .orange
        default: return .red
        }
    }
}

// MARK: - Device

struct DeviceDetailScreen: View {
    @ObservedObject var stats: DeviceStats
    private var s: DeviceSnapshot { stats.snapshot }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.marketingName)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(s.osVersion).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Identity") {
                CopyRow(name: "Model identifier", value: s.model, monospaced: true)
                CopyRow(name: "OS", value: s.osVersion)
            }
            Section("Uptime") {
                if let boot = s.bootDate {
                    PlainRow(name: "Booted", value: boot.formatted(date: .abbreviated, time: .shortened))
                }
                PlainRow(name: "Uptime", value: Fmt.uptime(s.bootUptime ?? s.uptime))
                PlainRow(name: "Awake time", value: Fmt.uptime(s.uptime))
            }
            Section("Cores") {
                PlainRow(name: "Total", value: "\(s.coresTotal)")
                if s.coresPerformance > 0 {
                    PlainRow(name: "Performance", value: "\(s.coresPerformance)")
                    PlainRow(name: "Efficiency", value: "\(s.coresEfficiency)")
                }
            }
        }
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
    }
}
