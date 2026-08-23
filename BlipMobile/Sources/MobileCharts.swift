import SwiftUI
import Charts

// Session-scope charts for iOS. The rule from the widgets applies inside the app too, inverted:
// HERE live sampling is honest (the app is open and polling), so cards chart the session —
// CPU, app-available memory, thermal steps — and the speed test draws its live curve. History
// starts when the app opens; pretending to have background history iOS never granted would lie.

struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor
    var height: CGFloat = 34
    /// Fix the domain for percent-style data so the chart doesn't dramatize noise.
    var fixedDomain: ClosedRange<Double>?

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(tint.opacity(0.18))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: fixedDomain ?? autoDomain)
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }

    private var autoDomain: ClosedRange<Double> {
        guard let min = values.min(), let max = values.max(), max > min else { return 0...1 }
        let pad = (max - min) * 0.15
        return (min - pad)...(max + pad)
    }
}

/// Thermal is a STEP function (0…3), so it gets a step chart, not a wiggly line.
struct ThermalSteps: View {
    let values: [Double]
    var height: CGFloat = 30

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            LineMark(x: .value("t", index), y: .value("state", value))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(color(for: value))
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: -0.2...3.2)
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }

    private func color(for v: Double) -> Color {
        switch Int(v) {
        case 0: return .green
        case 1: return .yellow
        case 2: return .orange
        default: return .red
        }
    }
}

/// Bench history as a bar chart — full runs solid, quick runs hollow (QA, not measurements).
struct BenchHistoryChart: View {
    let history: [BenchResult]

    var body: some View {
        Chart(history) { r in
            BarMark(x: .value("run", r.date, unit: .second),
                    y: .value("score", r.composite))
                .foregroundStyle(r.profile == .full ? Color.purple : Color.purple.opacity(0.35))
                .cornerRadius(2)
        }
        .chartXAxis(.hidden)
        .frame(height: 90)
    }
}
