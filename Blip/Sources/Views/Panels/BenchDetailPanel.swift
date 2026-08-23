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
        .frame(width: 300)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView(value: engine.progress)
                Text(engine.phase.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
            }
            if engine.phase == .sustained, let t = engine.liveThermal {
                HStack(spacing: 10) {
                    if let c = t.temperatureC {
                        Label(String(format: "%.0f °C", c), systemImage: "thermometer.medium")
                    }
                    if let rpm = t.fanRPM {
                        Label(String(format: "%.0f rpm", rpm), systemImage: "fan")
                    }
                    Label(thermalStateLabel(t.thermalState), systemImage: "flame")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func scoreCard(_ r: BenchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(r.composite.rounded()))")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("composite")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                deltaBadge(r)
            }

            VStack(alignment: .leading, spacing: 4) {
                categoryRow("Single-core", r.singleCore.score, "cpu")
                categoryRow("All cores", r.multiCore.score, "square.grid.3x3")
                categoryRow("Memory", r.memory.score, "memorychip")
                if let gpu = r.gpu { categoryRow("GPU", gpu.score, "cube.transparent") }
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

    private func categoryRow(_ name: String, _ score: Double, _ icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.purple)
                .frame(width: 14)
            Text(name).font(.system(size: 11))
            Spacer()
            Text("\(Int(score.rounded()))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
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
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(engine.history.count) runs")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            MiniChart(data: engine.history.map(\.composite), color: .purple, height: 28)
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
