import SwiftUI
import Charts

struct DiskDetailPanel: View {
    let stats: DiskStats
    let readHistory: [Double]
    let writeHistory: [Double]
    var hasIOData: Bool = true

    @StateObject private var speedTester = DiskSpeedTester()
    @State private var speedTestExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.orange)
                Text("Disk")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !stats.smartStatus.isEmpty {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(stats.smartStatus == "Verified" ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(stats.smartStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if hasIOData {
                // I/O Speed
                HStack(spacing: 0) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Total read/written since boot
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total Read")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(Fmt.totalBytes(stats.totalBytesRead))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total Written")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(Fmt.totalBytes(stats.totalBytesWritten))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // I/O History Chart
                if !readHistory.isEmpty || !writeHistory.isEmpty {
                    ioChart
                }

                Divider()
            }

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

            // Drive health (S.M.A.R.T.)
            if !stats.drives.isEmpty {
                Divider()
                ForEach(stats.drives) { drive in
                    driveHealthSection(drive)
                }
            }

            // Speed test (self-contained block — see speedTestSection below)
            Divider()
            speedTestSection
        }
        .padding(12)
        .frame(width: 260)
    }

    @ViewBuilder
    private func driveHealthSection(_ drive: DriveHealth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: drive.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(drive.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(drive.medium)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            // Life remaining (the headline metric)
            if let life = drive.lifeRemaining {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Life Remaining")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(life)%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(lifeColor(life))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(lifeColor(life))
                                .frame(width: geo.size.width * min(Double(life) / 100, 1))
                        }
                    }
                    .frame(height: 8)
                }
            }

            // Detail grid
            let cells = healthCells(drive)
            ForEach(Array(stride(from: 0, to: cells.count, by: 2)), id: \.self) { i in
                HStack(spacing: 0) {
                    healthCell(cells[i].0, cells[i].1)
                    if i + 1 < cells.count {
                        healthCell(cells[i + 1].0, cells[i + 1].1)
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }

            if !drive.isHealthy {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                    Text("S.M.A.R.T. warning")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Builds the (label, value) pairs that are available for this drive.
    private func healthCells(_ drive: DriveHealth) -> [(String, String)] {
        var cells: [(String, String)] = []
        if let used = drive.percentageUsed { cells.append(("Used", "\(used)%")) }
        if let spare = drive.availableSpare { cells.append(("Spare", "\(spare)%")) }
        if let temp = drive.temperatureCelsius { cells.append(("Temp", "\(temp)°C")) }
        if let written = drive.bytesWritten { cells.append(("Written", Fmt.totalBytes(written))) }
        if let read = drive.bytesRead { cells.append(("Read", Fmt.totalBytes(read))) }
        if let hours = drive.powerOnHours { cells.append(("Power On", "\(hours) h")) }
        if let cycles = drive.powerCycles { cells.append(("Cycles", "\(cycles)")) }
        if let unsafe = drive.unsafeShutdowns { cells.append(("Unsafe Off", "\(unsafe)")) }
        return cells
    }

    private func healthCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lifeColor(_ life: Int) -> Color {
        if life < 10 { return .red }
        if life < 25 { return .orange }
        return .green
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

    private var speedTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { speedTestExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("Speed Test")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    if let r = speedTester.lastResult, !speedTestExpanded {
                        Text(String(format: "%.0f / %.0f MB/s", r.readMBps, r.writeMBps))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: speedTestExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if speedTestExpanded {
                speedTestBody
            }
        }
    }

    private var speedTestBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Target location + change/reset
            HStack(spacing: 4) {
                Image(systemName: speedTester.locationLabel == "Boot volume" ? "internaldrive" : "externaldrive")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(speedTester.locationLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { speedTester.chooseLocation() }
                    .controlSize(.mini)
                    .disabled(speedTester.isRunning)
                if speedTester.locationLabel != "Boot volume" {
                    Button {
                        speedTester.useBootVolume()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .controlSize(.mini)
                    .disabled(speedTester.isRunning)
                    .help("Back to boot volume")
                }
            }

            if let err = speedTester.lastError {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // Size picker
            HStack {
                Text("Size")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $speedTester.size) {
                    ForEach(DiskBenchmark.Size.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 90)
                .disabled(speedTester.isRunning)
            }

            // Run / Cancel button + progress
            if speedTester.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView(value: speedTester.progress)
                            .progressViewStyle(.linear)
                        Button("Cancel") { speedTester.cancel() }
                            .controlSize(.mini)
                    }
                    Text(phaseLabel(speedTester.phase))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    speedTester.start()
                } label: {
                    Text("Run Test")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }

            // Last result
            if let r = speedTester.lastResult {
                HStack(spacing: 0) {
                    speedStat(title: "Read", value: r.readMBps, color: .green)
                    speedStat(title: "Write", value: r.writeMBps, color: .blue)
                }
                if let iops = r.randomReadIOPS {
                    HStack(spacing: 2) {
                        Text("Random read")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f IOPS", iops))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }

            // History sparkline
            if speedTester.history.count > 1 {
                speedHistoryChart
            }

            // Auto-run toggle
            Toggle(isOn: $speedTester.autoRun) {
                Text("Auto-run every \(speedTester.intervalMinutes) min")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    private func speedStat(title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(String(format: "%.0f MB/s", value))
                .font(.system(size: 11, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speedHistoryChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("History")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(Array(speedTester.history.enumerated()), id: \.offset) { i, r in
                    LineMark(x: .value("T", i), y: .value("Speed", r.readMBps), series: .value("Type", "Read"))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    LineMark(x: .value("T", i), y: .value("Speed", r.writeMBps), series: .value("Type", "Write"))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%.0f", v))
                                .font(.system(size: 7))
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2]))
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(height: 50)
        }
    }

    private func phaseLabel(_ phase: DiskBenchmark.Phase) -> String {
        switch phase {
        case .idle: return ""
        case .writing: return "Writing…"
        case .reading: return "Reading…"
        case .randomRead: return "Random read…"
        }
    }
}
