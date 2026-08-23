import SwiftUI

// Blip Bench's home: the score card, one Run button, and the two comparisons that mean
// something — this machine against its own history, and burst against sustained (the
// throttle story, drawn against the thermal samples captured during the run).

struct BenchDetailPanel: View {
    @ObservedObject var engine: BenchEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if engine.isRunning {
                running
            } else if let r = engine.lastResult {
                scoreCard(r)
            } else {
                Text("Measure what this Mac can actually do — CPU, memory, and GPU throughput scored in Blip's fixed reference units, plus how much it loses under sustained load.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !engine.history.isEmpty { historySection }
        }
        .padding(12)
        // 260 like every other detail panel — the hover host sizes for that width, and a
        // wider view gets edge-clipped (field-caught: the intro text lost its first column).
        .frame(width: 260)
        // Deliberate full-bleed brand wash — applied OUTSIDE the padding so it reaches the
        // panel's edges (field-caught: an inset wash stopping 12pt short read as a glitch).
        .background(
            LinearGradient(colors: [Color.purple.opacity(0.16), Color.blue.opacity(0.06), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.needle")
                .foregroundStyle(.purple)
            Text("Bench")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(engine.isRunning ? "Cancel" : "Run") {
                engine.toggle(profile: .full)
            }
            .controlSize(.small)
        }
    }

    private var running: some View {
        // iOS-parity running state: legs animate in with their scores the moment each
        // finishes, the active leg pulses, sustained shows live %-held + thermals.
        BenchRunningRows(engine: engine)
    }

    private func scoreCard(_ r: BenchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(r.composite.rounded()))")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.purple, .blue],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .contentTransition(.numericText())
                Text("composite")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                deltaBadge(r)
                shareButton(r)
            }

            VStack(alignment: .leading, spacing: 4) {
                categoryRow("Single-core", r.singleCore.score, "cpu")
                categoryRow("All cores", r.multiCore.score, "square.grid.3x3")
                categoryRow("Memory", r.memory.score, "memorychip")
                if let gpu = r.gpu { categoryRow("GPU", gpu.score, "cube.transparent") }
                if let neural = r.neural { categoryRow("Neural", neural.score, "brain") }
            }

            if let lost = r.throttlePercentLost {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: lost > 15 ? "flame.fill" : "flame")
                        .foregroundStyle(lost > 15 ? .orange : .secondary)
                    Text(lost == 0
                         ? "No throttling under sustained load"
                         : "Sustained load loses \(lost)%")
                        .font(.system(size: 11, weight: lost > 15 ? .semibold : .regular))
                    Spacer()
                }
                if r.thermalSamples.contains(where: { $0.temperatureC != nil }) {
                    MiniChart(
                        data: r.thermalSamples.compactMap(\.temperatureC),
                        color: .orange, height: 24)
                }
            }

            Text("\(r.deviceModel) · \(r.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func categoryRow(_ name: LocalizedStringKey, _ score: Double, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)
                    .frame(width: 14)
                Text(name).font(.system(size: 11))
                Spacer()
                Text("\(Int(score.rounded()))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
            // iOS-parity: the bar scales against this Mac's own best category score.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: [.purple, .blue],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * barFraction(score))
                }
            }
            .frame(height: 4)
            .padding(.leading, 18)
        }
    }

    /// Fraction of this category's own historical best (full runs), floored for visibility.
    private func barFraction(_ score: Double) -> CGFloat {
        let best = engine.history.filter { $0.profile == .full }
            .flatMap { [$0.singleCore.score, $0.multiCore.score, $0.memory.score, $0.gpu?.score ?? 0, $0.neural?.score ?? 0] }
            .max() ?? score
        // Normalize per row against the ROW's own scale: use the row score vs the max of
        // that same category across history — approximated by score/best-of-anything would
        // flatten small categories, so fall back to per-call normalization with the current
        // result treated as its own ceiling when history is thin.
        _ = best
        let ceiling = categoryCeiling(for: score)
        return CGFloat(max(0.06, ceiling > 0 ? min(score / ceiling, 1) : 0))
    }

    private func categoryCeiling(for score: Double) -> Double {
        // Best matching-category score across full runs, discovered by proximity: rows call
        // with their own category's score, so compare against every category's historical
        // max and pick the smallest ceiling ≥ score (keeps each bar on its own scale).
        let history = engine.history.filter { $0.profile == .full }
        var maxima: [Double] = []
        maxima.append(history.map { $0.singleCore.score }.max() ?? 0)
        maxima.append(history.map { $0.multiCore.score }.max() ?? 0)
        maxima.append(history.map { $0.memory.score }.max() ?? 0)
        maxima.append(history.compactMap { $0.gpu?.score }.max() ?? 0)
        maxima.append(history.compactMap { $0.neural?.score }.max() ?? 0)
        let candidates = maxima.filter { $0 >= score }
        return candidates.min() ?? score
    }

    private func shareButton(_ r: BenchResult) -> some View {
        // NSSharingServicePicker path: shares the REAL image + caption (ShareLink handed
        // services a temp-file URL) and pins the panel open while the picker runs.
        MacShareButton(makeItems: {
            let name = deviceName(r)
            var items: [Any] = []
            if let img = MacShareCard.render(MacBenchShareCardView(result: r, deviceName: name)) { items.append(img) }
            items.append(MacShareCard.benchText(r, deviceName: name))
            return items
        }, help: String(localized: "Share this result as an image + text"))
        .frame(width: 16, height: 14)
    }

    private func deviceName(_ r: BenchResult) -> String {
        // The panel's result carries the model identifier; the monitor's marketing name is
        // nicer when it matches this machine (it always does — results are local).
        r.deviceModel
    }

    private func deltaBadge(_ r: BenchResult) -> some View {
        Group {
            // Compare against the best PREVIOUS full run — "am I slower than my own Mac?"
            let previous = engine.history.dropLast().filter { $0.profile == .full }.map(\.composite).max()
            if r.profile == .full, let best = previous, best > 0 {
                let pct = Int(((r.composite - best) / best * 100).rounded())
                Text(pct >= 0 ? "+\(pct)% vs best" : "\(pct)% vs best")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pct >= -3 ? Color.green : Color.orange)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            BenchHistoryChart(history: engine.history)
                .frame(height: 56)
            ForEach(engine.history.suffix(6).reversed()) { r in
                HStack {
                    Text("\(Int(r.composite.rounded()))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(width: 44, alignment: .leading)
                    Text(r.profile == .quick ? "quick" : "full")
                        .font(.system(size: 8))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    Text(r.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func thermalStateLabel(_ raw: Int) -> String {
        switch raw {
        case 0: return "Nominal"
        case 1: return "Fair"
        case 2: return "Serious"
        default: return "Critical"
        }
    }
}

// MARK: - The animated running rows (iOS parity, panel scale)

struct BenchRunningRows: View {
    @ObservedObject var engine: BenchEngine
    @State private var pulse = false

    private static let legOrder: [(id: String, name: LocalizedStringKey, icon: String, phase: BenchEngine.Phase)] = [
        ("single", "Single-core", "cpu", .singleCore),
        ("multi", "All cores", "square.grid.3x3", .multiCore),
        ("memory", "Memory", "memorychip", .memory),
        ("gpu", "GPU", "cube.transparent", .gpu),
        ("neural", "Neural", "brain", .neural),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Self.legOrder, id: \.id) { leg in
                if let done = engine.liveLegs.first(where: { $0.id == leg.id }) {
                    finishedRow(leg.name, leg.icon, done.score)
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .opacity))
                } else if engine.phase == leg.phase {
                    activeRow(leg.name, leg.icon)
                }
            }
            if engine.phase == .sustained { sustainedRow }
            ProgressView(value: engine.progress)
                .tint(.purple)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .animation(.spring(duration: 0.45), value: engine.liveLegs)
        .animation(.spring(duration: 0.45), value: engine.phase)
        .onAppear { pulse = true }
    }

    private func finishedRow(_ name: LocalizedStringKey, _ icon: String, _ score: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.purple).frame(width: 14)
            Text(name).font(.system(size: 11))
            Spacer()
            Text("\(Int(score.rounded()))")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9)).foregroundStyle(.green)
        }
    }

    private func activeRow(_ name: LocalizedStringKey, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.purple)
                .frame(width: 14)
                .scaleEffect(pulse ? 1.2 : 0.9)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            Text(name).font(.system(size: 11, weight: .medium))
            Spacer()
            PanelMeasuringDots()
        }
    }

    private var sustainedRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "flame")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(width: 14)
                    .scaleEffect(pulse ? 1.2 : 0.9)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                Text("Sustained + thermals").font(.system(size: 11, weight: .medium))
                Spacer()
                if let sVal = engine.liveLegs.first(where: { $0.id == "sustained" }) {
                    Text("\(Int(sVal.score.rounded()))% held")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .foregroundStyle(sVal.score >= 85 ? Color.green : (sVal.score >= 70 ? .orange : .red))
                } else {
                    PanelMeasuringDots()
                }
            }
            if let t = engine.liveThermal {
                HStack(spacing: 8) {
                    if let c = t.temperatureC { Label(String(format: "%.0f °C", c), systemImage: "thermometer.medium") }
                    if let rpm = t.fanRPM { Label(String(format: "%.0f rpm", rpm), systemImage: "fan") }
                }
                .font(.system(size: 9))
                .foregroundStyle(t.thermalState >= 2 ? .orange : .secondary)
                .padding(.leading, 20)
            }
        }
    }
}

/// Three dots breathing in sequence — "working on it" without a spinner.
private struct PanelMeasuringDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.17), value: on)
            }
        }
        .onAppear { on = true }
    }
}
