import SwiftUI

struct MemoryDetailPanel: View {
    let stats: MemoryStats
    let history: [Double]
    let topProcesses: [ProcessInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "memorychip")
                    .foregroundStyle(.green)
                Text("Memory")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Fmt.percent(stats.usagePercent))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }

            // Total
            HStack {
                Text("Total")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.bytes(stats.total))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            // Breakdown
            VStack(spacing: 4) {
                memoryRow("Used", value: stats.used, color: .green)
                memoryRow("Wired", value: stats.wired, color: .orange)
                memoryRow("Compressed", value: stats.compressed, color: .purple)
                memoryRow("App Memory", value: stats.appMemory, color: .blue)
                memoryRow("Free", value: stats.free, color: .gray)
            }

            // Pressure bar
            HStack(spacing: 4) {
                Text("Pressure")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.green.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(pressureColor)
                            .frame(width: geo.size.width * min(stats.usagePercent / 100, 1))
                    }
                }
                .frame(height: 6)
            }

            // Chart
            DetailChart(data: history, color: .green, label: "Usage over time")

            // Top processes
            if !topProcesses.isEmpty {
                Divider()
                Text("Top Processes")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(topProcesses) { proc in
                    ProcessRow(process: proc, mode: .memory)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func memoryRow(_ label: String, value: UInt64, color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
            Spacer()
            Text(Fmt.bytes(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var pressureColor: Color {
        if stats.usagePercent > 90 { return .red }
        if stats.usagePercent > 75 { return .orange }
        return .green
    }
}
