import SwiftUI
import Charts

/// Compact sparkline chart for historical data.
struct MiniChart: View {
    let data: [Double]
    let color: Color
    let height: CGFloat

    init(data: [Double], color: Color = .accentColor, height: CGFloat = 30) {
        self.data = data
        self.color = color
        self.height = height
    }

    var body: some View {
        Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { index, value in
                AreaMark(
                    x: .value("Time", index),
                    y: .value("Usage", value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.4), color.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", index),
                    y: .value("Usage", value)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

/// Larger chart with axes for detail panels.
struct DetailChart: View {
    let data: [Double]
    let color: Color
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(Array(data.enumerated()), id: \.offset) { index, value in
                    AreaMark(
                        x: .value("Time", index),
                        y: .value("Usage", value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.3), color.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Time", index),
                        y: .value("Usage", value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)%")
                                .font(.system(size: 8))
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2]))
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(height: 80)
        }
    }
}
