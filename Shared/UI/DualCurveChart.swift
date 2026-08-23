import SwiftUI
import Charts

/// Download + upload as two distinct series in complementary colors — teal for down,
/// coral/orange for up — instead of one undifferentiated line.
struct DualCurveChart: View {
    let down: [Double]
    let up: [Double]
    var height: CGFloat = 70

    var body: some View {
        Chart {
            ForEach(Array(down.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("t", i), y: .value("Mbps", v), series: .value("dir", "down"))
                    .foregroundStyle(Color.teal)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("t", i), y: .value("Mbps", v), series: .value("adir", "down"))
                    .foregroundStyle(Color.teal.opacity(0.14))
                    .interpolationMethod(.monotone)
            }
            ForEach(Array(up.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("t", down.count + i), y: .value("Mbps", v), series: .value("dir", "up"))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("t", down.count + i), y: .value("Mbps", v), series: .value("adir", "up"))
                    .foregroundStyle(Color.orange.opacity(0.14))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}
