import SwiftUI
import Charts

/// Bench history as a bar chart — full runs solid, quick runs hollow (QA, not measurements).
struct BenchHistoryChart: View {
    let history: [BenchResult]
    var height: CGFloat = 90

    var body: some View {
        // Index-based x. Date-based BarMarks with `unit: .second` made each bar 1 second
        // wide on an axis spanning the whole history — sub-pixel, i.e. an empty chart
        // (field-reported: "the history chart doesn't render anything").
        Chart(Array(history.enumerated()), id: \.offset) { index, r in
            BarMark(x: .value("run", index),
                    y: .value("score", r.composite),
                    width: .fixed(14))   // fixed: .ratio needs a band scale; index-x is continuous → zero-width bars
                .foregroundStyle(r.profile == .full ? Color.purple : Color.purple.opacity(0.35))
                .cornerRadius(3)
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: -0.5...(Double(max(history.count, 1)) - 0.5))
        .frame(height: height)
        .clipped()
    }
}
