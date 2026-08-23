import SwiftUI

// Blip Bench on the phone — same BenchKit engine, same frozen reference units, so an iPhone
// score and a Mac score live on one scale. Guardrails a phone actually needs: warn on battery
// and on pre-warmed thermals before the full profile (a hot pocket-phone measures its case,
// not its silicon).
//
// The running state earned field feedback ("mostly blank until it completes") — it now
// narrates the run: legs animate in with their scores the moment each finishes, the active
// leg pulses, and the sustained phase shows live retention percent + thermal state.

struct BenchScreen: View {
    @ObservedObject var engine: BenchEngine
    @ObservedObject var stats: DeviceStats

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    guardrails
                    if engine.isRunning { BenchRunningView(engine: engine) }
                    else if let r = engine.lastResult { ScoreCard(result: r, history: engine.history) }
                    else { intro }
                    runButton
                    if let r = engine.lastResult, !engine.isRunning { shareRow(r) }
                    if !engine.history.isEmpty { history }
                }
                .padding()
            }
            .navigationTitle("Bench")
        }
        .onChange(of: engine.lastResult) { _, _ in MobileSharedStore.benchUpdated() }
    }

    private var intro: some View {
        Text("Measure what this device can actually do — CPU, memory, and GPU throughput in Blip's fixed reference units, comparable with any Mac or iPhone running Blip. The full profile adds a sustained phase that shows how much performance thermal limits take back.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var guardrails: some View {
        Group {
            if stats.snapshot.batteryState == "On battery" {
                Label("On battery — scores can read low. Plug in for a fair full run.",
                      systemImage: "battery.25")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if stats.snapshot.thermalState >= 2 {
                Label("Device is already \(stats.snapshot.thermalLabel.lowercased()) — let it cool before benchmarking.",
                      systemImage: "thermometer.high")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var runButton: some View {
        Button {
            engine.toggle(profile: .full)
        } label: {
            Text(engine.isRunning ? "Cancel" : "Run Full Benchmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.isRunning ? .red : .purple)
    }

    private func shareRow(_ r: BenchResult) -> some View {
        ShareLink(
            item: SharePayload(image: ShareCard.render(BenchShareCardView(result: r)) ?? UIImage(),
                               text: ShareCard.benchText(r)),
            preview: SharePreview("Blip Bench \(Int(r.composite.rounded()))",
                                  image: Image(uiImage: ShareCard.render(BenchShareCardView(result: r)) ?? UIImage()))
        ) {
            Label("Share Result", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History").font(.headline)
            BenchHistoryChart(history: engine.history)
            ForEach(engine.history.suffix(8).reversed()) { r in
                HStack {
                    Text("\(Int(r.composite.rounded()))")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .frame(width: 64, alignment: .leading)
                    Text(r.profile == .quick ? "quick" : "full")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    Text(r.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - The animated running view

struct BenchRunningView: View {
    @ObservedObject var engine: BenchEngine
    @State private var pulse = false

    private static let legOrder: [(id: String, name: String, icon: String, phase: BenchEngine.Phase)] = [
        ("single", "Single-core", "cpu", .singleCore),
        ("multi", "All cores", "square.grid.3x3", .multiCore),
        ("memory", "Memory", "memorychip", .memory),
        ("gpu", "GPU", "cube.transparent", .gpu),
        ("neural", "Neural", "brain", .neural),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .padding(.top, 4)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .animation(.spring(duration: 0.45), value: engine.liveLegs)
        .animation(.spring(duration: 0.45), value: engine.phase)
        .onAppear { pulse = true }
    }

    private func finishedRow(_ name: String, _ icon: String, _ score: Double) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.purple).frame(width: 26)
            Text(name).font(.subheadline)
            Spacer()
            Text("\(Int(score.rounded()))")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .contentTransition(.numericText())
            Image(systemName: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        }
    }

    private func activeRow(_ name: String, _ icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.purple)
                .frame(width: 26)
                .scaleEffect(pulse ? 1.18 : 0.92)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            Text(name).font(.subheadline.weight(.medium))
            Spacer()
            MeasuringDots()
        }
    }

    private var sustainedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "flame")
                    .foregroundStyle(.orange)
                    .frame(width: 26)
                    .scaleEffect(pulse ? 1.18 : 0.92)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                Text("Sustained + thermals").font(.subheadline.weight(.medium))
                Spacer()
                if let s = engine.liveLegs.first(where: { $0.id == "sustained" }) {
                    Text("\(Int(s.score.rounded()))% held")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .contentTransition(.numericText())
                        .foregroundStyle(s.score >= 85 ? Color.green : (s.score >= 70 ? .orange : .red))
                } else {
                    MeasuringDots()
                }
            }
            if let t = engine.liveThermal {
                Text("Thermal state: \(["nominal", "fair", "serious", "critical"][min(t.thermalState, 3)])")
                    .font(.caption).foregroundStyle(t.thermalState >= 2 ? .orange : .secondary)
                    .padding(.leading, 34)
            }
        }
    }
}

/// Three dots breathing in sequence — "working on it" without a spinner.
struct MeasuringDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.17), value: on)
            }
        }
        .onAppear { on = true }
    }
}

struct ScoreCard: View {
    let result: BenchResult
    let history: [BenchResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Hero: the composite, big, with how it sits against this device's best.
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(result.composite.rounded()))")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.purple, .blue],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 0) {
                    Text("composite").font(.subheadline).foregroundStyle(.secondary)
                    Text(result.profile == .quick ? "quick run" : "full run")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                delta
            }

            // Category bars, each scaled against this device's own best — the comparison
            // that diagnoses something (reference units already handle cross-device).
            VStack(spacing: 8) {
                categoryBar("Single-core", "cpu", result.singleCore.score, best(\.singleCore))
                categoryBar("All cores", "square.grid.3x3", result.multiCore.score, best(\.multiCore))
                categoryBar("Memory", "memorychip", result.memory.score, best(\.memory))
                if let gpu = result.gpu {
                    categoryBar("GPU", "cube.transparent", gpu.score, bestOptional(\.gpu))
                }
                if let neural = result.neural {
                    categoryBar("Neural", "brain", neural.score, bestOptional(\.neural))
                }
            }

            if let lost = result.throttlePercentLost {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(lost == 0 ? "No throttling under sustained load"
                                    : "Sustained load loses \(lost)%",
                          systemImage: lost > 15 ? "flame.fill" : "flame")
                        .font(.footnote)
                        .foregroundStyle(lost > 15 ? .orange : .secondary)
                    if result.thermalSamples.count > 2 {
                        ThermalSteps(values: result.thermalSamples.map { Double($0.thermalState) }, height: 26)
                    }
                }
            }

            HStack {
                Text(DeviceNames.name(for: result.deviceModel))
                Spacer()
                Text(result.date.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Best full-run score for a category across history (including this run).
    private func best(_ path: KeyPath<BenchResult, BenchCategoryScore>) -> Double {
        max(history.filter { $0.profile == .full }.map { $0[keyPath: path].score }.max() ?? 0,
            result[keyPath: path].score)
    }
    private func bestOptional(_ path: KeyPath<BenchResult, BenchCategoryScore?>) -> Double {
        max(history.filter { $0.profile == .full }.compactMap { $0[keyPath: path]?.score }.max() ?? 0,
            result[keyPath: path]?.score ?? 0)
    }

    private func categoryBar(_ name: String, _ icon: String, _ score: Double, _ best: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(name, systemImage: icon).font(.subheadline)
                Spacer()
                Text("\(Int(score.rounded()))")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: [.purple, .blue],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * max(0.04, best > 0 ? score / best : 0))
                }
            }
            .frame(height: 5)
        }
    }

    private var delta: some View {
        Group {
            let previous = history.dropLast().filter { $0.profile == .full }.map(\.composite).max()
            if result.profile == .full, let best = previous, best > 0 {
                let pct = Int(((result.composite - best) / best * 100).rounded())
                VStack(spacing: 0) {
                    Text(pct >= 0 ? "+\(pct)%" : "\(pct)%")
                        .font(.headline)
                        .foregroundStyle(pct >= -3 ? Color.green : Color.orange)
                    Text("vs best").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
