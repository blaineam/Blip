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

            // Breakdown (matches Activity Monitor categories)
            VStack(spacing: 4) {
                memoryRow("App Memory", value: stats.appMemory, color: .blue)
                memoryRow("Wired", value: stats.wired, color: .orange)
                memoryRow("Compressed", value: stats.compressed, color: .purple)
            }

            Divider()

            VStack(spacing: 4) {
                memoryRow("Memory Used", value: stats.used, color: .green)
                memoryRow("Cached Files", value: stats.cachedFiles, color: .cyan)
                memoryRow("Free", value: stats.free, color: .gray)
            }

            // Swap (always shown)
            VStack(spacing: 4) {
                HStack {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 6, height: 6)
                    Text("Swap Used")
                        .font(.system(size: 11))
                    Spacer()
                    Text(Fmt.bytes(stats.swapUsed))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if stats.swapTotal > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.yellow.opacity(0.1))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.yellow)
                                .frame(width: geo.size.width * min(Double(stats.swapUsed) / Double(stats.swapTotal), 1))
                        }
                    }
                    .frame(height: 6)
                }
            }

            // Pressure bar (uses kernel pressure level)
            HStack(spacing: 4) {
                Text("Pressure")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(pressureColor.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(pressureColor)
                            .frame(width: geo.size.width * pressureBarFill)
                    }
                }
                .frame(height: 6)
                Text(pressureLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(pressureColor)
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

    // Kernel pressure level: 1=normal, 2=warning, 4=critical
    private var pressureColor: Color {
        switch stats.pressureLevel {
        case 1: return .green
        case 2: return .yellow
        case 4: return .red
        default: return .green
        }
    }

    private var pressureLabel: String {
        switch stats.pressureLevel {
        case 1: return "Normal"
        case 2: return "Warning"
        case 4: return "Critical"
        default: return "Normal"
        }
    }

    private var pressureBarFill: Double {
        switch stats.pressureLevel {
        case 1: return 0.15
        case 2: return 0.55
        case 4: return 1.0
        default: return 0.15
        }
    }
}
