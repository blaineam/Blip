import SwiftUI

// Blip Bench on the phone — same BenchKit engine, same frozen reference units, so an iPhone
// score and a Mac score live on one scale. Guardrails a phone actually needs: warn on battery
// and on pre-warmed thermals before the full profile (a hot pocket-phone measures its case,
// not its silicon).

struct BenchScreen: View {
    @ObservedObject var engine: BenchEngine
    @ObservedObject var stats: DeviceStats

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    guardrails
                    if engine.isRunning { running }
                    else if let r = engine.lastResult { ScoreCard(result: r, history: engine.history) }
                    else { intro }
                    runButton
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

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: engine.progress)
            HStack {
                Text(engine.phase.label).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if engine.phase == .sustained, let t = engine.liveThermal {
                    Text(thermalLabel(t.thermalState))
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 8)
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

    private func thermalLabel(_ raw: Int) -> String {
        ["Nominal", "Fair", "Serious", "Critical"][min(raw, 3)]
    }
}

struct ScoreCard: View {
    let result: BenchResult
    let history: [BenchResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(result.composite.rounded()))")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("composite").foregroundStyle(.secondary)
                Spacer()
                delta
            }
            row("Single-core", result.singleCore.score, "cpu")
            row("All cores", result.multiCore.score, "square.grid.3x3")
            row("Memory", result.memory.score, "memorychip")
            if let gpu = result.gpu { row("GPU", gpu.score, "cube.transparent") }
            if let lost = result.throttlePercentLost {
                Divider()
                Label(lost == 0 ? "No throttling under sustained load"
                                : "Sustained load loses \(lost)%",
                      systemImage: lost > 15 ? "flame.fill" : "flame")
                    .font(.footnote)
                    .foregroundStyle(lost > 15 ? .orange : .secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private var delta: some View {
        Group {
            let previous = history.dropLast().filter { $0.profile == .full }.map(\.composite).max()
            if result.profile == .full, let best = previous, best > 0 {
                let pct = Int(((result.composite - best) / best * 100).rounded())
                Text(pct >= 0 ? "+\(pct)%" : "\(pct)%")
                    .font(.headline)
                    .foregroundStyle(pct >= -3 ? Color.green : Color.orange)
            }
        }
    }

    private func row(_ name: String, _ score: Double, _ icon: String) -> some View {
        HStack {
            Label(name, systemImage: icon).font(.subheadline)
            Spacer()
            Text("\(Int(score.rounded()))")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
        }
    }
}
