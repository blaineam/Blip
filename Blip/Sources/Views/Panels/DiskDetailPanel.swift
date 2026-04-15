import SwiftUI
import Charts

struct DiskDetailPanel: View {
    let stats: DiskStats
    let readHistory: [Double]
    let writeHistory: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.orange)
                Text("Disk")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            // I/O Speed
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                        Text("Read")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(Fmt.speed(stats.readBytesPerSec))
                        .font(.system(size: 11, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                        Text("Write")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(Fmt.speed(stats.writeBytesPerSec))
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            // I/O History Chart
            if !readHistory.isEmpty || !writeHistory.isEmpty {
                ioChart
            }

            Divider()

            // Volumes
            ForEach(stats.volumes) { volume in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: volume.mountPoint == "/" ? "internaldrive.fill" : "externaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(volume.name)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(Fmt.percent(volume.usagePercent))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange.opacity(0.1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(volumeColor(volume.usagePercent))
                                .frame(width: geo.size.width * min(volume.usagePercent / 100, 1))
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text("\(Fmt.diskBytes(volume.usedBytes)) used")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Fmt.diskBytes(volume.freeBytes)) free")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                if volume.id != stats.volumes.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var ioChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Read / Write over time")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(Array(readHistory.enumerated()), id: \.offset) { i, val in
                    AreaMark(x: .value("T", i), yStart: .value("Baseline", 0), yEnd: .value("Speed", val), series: .value("Type", "Read"))
                        .foregroundStyle(.green.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("T", i), y: .value("Speed", val), series: .value("Type", "Read"))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                ForEach(Array(writeHistory.enumerated()), id: \.offset) { i, val in
                    AreaMark(x: .value("T", i), yStart: .value("Baseline", 0), yEnd: .value("Speed", val), series: .value("Type", "Write"))
                        .foregroundStyle(.blue.opacity(0.12))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("T", i), y: .value("Speed", val), series: .value("Type", "Write"))
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
                    Text("Read").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Circle().fill(.blue).frame(width: 5, height: 5)
                    Text("Write").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func volumeColor(_ percent: Double) -> Color {
        if percent > 90 { return .red }
        if percent > 75 { return .orange }
        return .orange.opacity(0.8)
    }
}
