import SwiftUI

struct CPUDetailPanel: View {
    let stats: CPUStats
    let history: [Double]
    let topProcesses: [ProcessInfo]

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
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("User")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(Fmt.percent(stats.userUsage))
                        .font(.system(size: 11, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("System")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(Fmt.percent(stats.systemUsage))
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            // Core counts
            HStack(spacing: 12) {
                if stats.performanceCores > 0 {
                    coreLabel("P-Cores", count: stats.performanceCores)
                    coreLabel("E-Cores", count: stats.efficiencyCores)
                }
                coreLabel("Logical", count: stats.logicalCores)
            }

            // Load averages
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Load 1m")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f", stats.loadAverage1))
                        .font(.system(size: 11, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("5m")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f", stats.loadAverage5))
                        .font(.system(size: 11, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("15m")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f", stats.loadAverage15))
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            // Per-core bars — grid layout for compactness
            if !stats.coreUsages.isEmpty {
                let columns = stats.coreUsages.count > 16 ? 4 : (stats.coreUsages.count > 8 ? 2 : 1)
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
                Text("Top Processes")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(topProcesses) { proc in
                    ProcessRow(process: proc, mode: .cpu)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func coreColor(_ usage: Double) -> Color {
        if usage > 90 { return .red }
        if usage > 70 { return .orange }
        return .blue
    }

    private func coreLabel(_ label: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
