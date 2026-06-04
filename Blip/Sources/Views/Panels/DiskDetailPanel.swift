import SwiftUI
import Charts

struct DiskDetailPanel: View {
    let stats: DiskStats
    let readHistory: [Double]
    let writeHistory: [Double]
    var hasIOData: Bool = true
    /// Persistent tester injected by the app so results/history survive the panel
    /// being dismissed and reopened.
    @ObservedObject var speedTester: DiskSpeedTester
    @AppStorage("diskSpeedExpanded") private var speedTestExpanded = false
    // Auto-run persisted here so the switch reflects state after dismiss/reopen.
    @AppStorage("diskSpeedAutoRun") private var diskAutoRunPref = false
    @AppStorage("diskSpeedInterval") private var diskIntervalPref = 5

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
                Text(drive.medium)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !drive.smartStatus.isEmpty {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(drive.isHealthy ? Color.green : Color.red)
                            .frame(width: 5, height: 5)
                        Text(drive.smartStatus)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(drive.isHealthy ? Color.secondary : Color.red)
                    }
                }
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

            // NVMe-over-USB / USB-SATA bridges typically pass through only the overall
            // pass/fail verdict, not the underlying drive's wear/temperature attributes
            // — say so rather than show an empty card. (Verified via deep IOKit probing:
            // the bridge returns a valid status but no real attribute table.)
            if drive.lifeRemaining == nil && cells.isEmpty {
                Text("Overall status only — this drive's USB bridge doesn't pass through wear/temperature details. The Verified/Failing verdict is reliable.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Hover help explaining each S.M.A.R.T. metric (these confuse people — notably
    /// "Used" can exceed 100% while "Spare" is a separate 0–100% reserve metric).
    private static let metricHelp: [String: String] = [
        "Used": "NVMe “Percentage Used” — estimated share of the drive's rated write endurance that has been consumed. Per the NVMe spec this can exceed 100% once the drive passes its rated lifespan (it may still work fine). Life Remaining = 100 − Used.",
        "Spare": "NVMe “Available Spare” — percentage of the drive's reserve (over-provisioned) blocks still available. Starts at 100% and falls as failing blocks are retired. A different metric from Used.",
        "Temp": "Current drive/controller temperature.",
        "Written": "Total data written over the drive's lifetime.",
        "Read": "Total data read over the drive's lifetime.",
        "Power On": "Cumulative hours the drive has been powered on.",
        "Cycles": "Number of power-on cycles.",
        "Unsafe Off": "Count of unsafe/unexpected shutdowns recorded by the drive.",
    ]

    private func healthCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Self.metricHelp[label] ?? "")
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
            HStack(spacing: 5) {
                Image(systemName: speedTester.locationLabel == "Boot volume" ? "internaldrive" : "externaldrive")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(speedTester.locationLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if speedTester.locationLabel != "Boot volume" {
                    Button { speedTester.useBootVolume() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(speedTester.isRunning)
                    .help("Back to boot volume")
                }
                Button("Change…") { speedTester.chooseLocation() }
                    .controlSize(.mini)
                    .disabled(speedTester.isRunning)
            }

            if let err = speedTester.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            // Size picker + Run/Cancel on one tidy row
            HStack(spacing: 6) {
                Picker("", selection: $speedTester.size) {
                    ForEach(DiskBenchmark.Size.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(speedTester.isRunning)
                Spacer()
                if speedTester.isRunning {
                    Button("Cancel") { speedTester.cancel() }
                        .controlSize(.small)
                        .tint(.red)
                } else {
                    Button { speedTester.start() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text("Run").font(.system(size: 10, weight: .medium))
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }

            if speedTester.isRunning {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: speedTester.progress).progressViewStyle(.linear)
                    Text(phaseLabel(speedTester.phase))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            // Last result — read / write / random IOPS in one row
            if let r = speedTester.lastResult {
                HStack(spacing: 0) {
                    speedStat(title: "Read", value: r.readMBps, color: .green)
                    speedStat(title: "Write", value: r.writeMBps, color: .blue)
                    if let iops = r.randomReadIOPS {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 2) {
                                Circle().fill(.orange).frame(width: 5, height: 5)
                                Text("Rand").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Text(iops >= 1000 ? String(format: "%.0fK IOPS", iops / 1000)
                                              : String(format: "%.0f IOPS", iops))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // History sparkline
            if !speedTester.history.isEmpty {
                speedHistoryChart
            }

            // Auto-run
            BlipToggle(title: "Auto-run on interval", isOn: $diskAutoRunPref) { v in speedTester.autoRun = v }
            if diskAutoRunPref {
                Picker("", selection: $diskIntervalPref) {
                    ForEach([1, 5, 15, 30, 60], id: \.self) { m in
                        Text("every \(m) min").tag(m)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .font(.system(size: 10))
                .onChange(of: diskIntervalPref) { _, v in speedTester.intervalMinutes = v }
                if !speedTester.autoRunAllowedNow {
                    Text("Paused — drive health is low. Manual runs still work.")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            speedTester.targetHealthRemaining = testedDriveHealth
            if speedTester.autoRun != diskAutoRunPref { speedTester.autoRun = diskAutoRunPref }
            if speedTester.intervalMinutes != diskIntervalPref { speedTester.intervalMinutes = diskIntervalPref }
        }
        .onChange(of: speedTester.locationLabel) { _, _ in speedTester.targetHealthRemaining = testedDriveHealth }
        .onChange(of: stats.drives.count) { _, _ in speedTester.targetHealthRemaining = testedDriveHealth }
    }

    /// Health % of the drive being benchmarked: the internal SSD for the boot volume,
    /// or unknown (nil → no guard) for a user-chosen external folder.
    private var testedDriveHealth: Int? {
        if speedTester.locationLabel == "Boot volume" {
            return stats.drives.first(where: { $0.isInternal })?.lifeRemaining
        }
        return nil
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
                    // Visible point for each run, including the first single sample.
                    PointMark(x: .value("T", i), y: .value("Speed", r.readMBps))
                        .foregroundStyle(.green)
                        .symbolSize(18)
                    PointMark(x: .value("T", i), y: .value("Speed", r.writeMBps))
                        .foregroundStyle(.blue)
                        .symbolSize(18)
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
