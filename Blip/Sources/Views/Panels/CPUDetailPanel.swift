import SwiftUI

struct CPUDetailPanel: View {
    let stats: CPUStats
    let history: [Double]
    let topProcesses: [ProcessInfo]
    /// Optional kill handler forwarded to each ProcessRow (Feature A).
    var onKill: ((pid_t, Bool) async -> (ok: Bool, message: String))? = nil
    /// Called with true while the pointer is over the process list so the app can
    /// freeze refreshes (stops reshuffling + preserves the two-click kill state).
    var onProcessHover: ((Bool) -> Void)? = nil
    /// Persistent armed-PID for the two-click kill confirm.
    var armedPID: Binding<pid_t?> = .constant(nil)
    @State private var processHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "cpu")
                    .foregroundStyle(.blue)
                Text("CPU")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Fmt.percent(stats.totalUsage))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }

            // Usage breakdown
            HStack(spacing: 0) {
                statColumn("User", value: Fmt.percent(stats.userUsage))
                statColumn("System", value: Fmt.percent(stats.systemUsage))
                statColumn("Idle", value: Fmt.percent(max(100 - stats.totalUsage, 0)), secondary: true)
            }

            // Core counts
            HStack(spacing: 0) {
                if stats.performanceCores > 0 {
                    statColumn("P-Cores", value: "\(stats.performanceCores)")
                    statColumn("E-Cores", value: "\(stats.efficiencyCores)")
                }
                statColumn("Logical", value: "\(stats.logicalCores)")
            }

            // Load averages
            HStack(spacing: 0) {
                statColumn("Load 1m", value: String(format: "%.2f", stats.loadAverage1))
                statColumn("5m", value: String(format: "%.2f", stats.loadAverage5))
                statColumn("15m", value: String(format: "%.2f", stats.loadAverage15))
            }

            // Per-core bars — grid layout for compactness
            if !stats.coreUsages.isEmpty {
                let columns = stats.coreUsages.count > 16 ? 4 : (stats.coreUsages.count > 12 ? 3 : (stats.coreUsages.count > 8 ? 2 : 1))
                let rows = (stats.coreUsages.count + columns - 1) / columns

                VStack(spacing: 2) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(0..<columns, id: \.self) { col in
                                let idx = row * columns + col
                                if idx < stats.coreUsages.count {
                                    HStack(spacing: 2) {
                                        Text("\(idx)")
                                            .font(.system(size: 7, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: columns > 2 ? 10 : 12, alignment: .trailing)
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 1.5)
                                                    .fill(Color.blue.opacity(0.1))
                                                RoundedRectangle(cornerRadius: 1.5)
                                                    .fill(coreColor(stats.coreUsages[idx]))
                                                    .frame(width: geo.size.width * min(stats.coreUsages[idx] / 100, 1))
                                            }
                                        }
                                        .frame(height: 4)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // History chart
            DetailChart(data: history, color: .blue, label: "Usage over time")

            // Top processes
            if !topProcesses.isEmpty {
                Divider()
                HStack(spacing: 4) {
                    Text("Top Processes")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if processHovering {
                        Label("paused", systemImage: "pause.fill")
                            .font(.system(size: 8))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                VStack(spacing: 0) {
                    ForEach(topProcesses) { proc in
                        ProcessRow(process: proc, mode: .cpu, onKill: onKill, armedPID: armedPID)
                    }
                }
                .onHover { h in
                    processHovering = h
                    onProcessHover?(h)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
        .onDisappear { onProcessHover?(false) }
    }

    private func coreColor(_ usage: Double) -> Color {
        if usage > 90 { return .red }
        if usage > 70 { return .orange }
        return .blue
    }

    private func statColumn(_ label: String, value: String, secondary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(secondary ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
