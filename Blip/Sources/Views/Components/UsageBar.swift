import SwiftUI

/// Compact horizontal usage bar with percentage label.
struct UsageBar: View {
    let value: Double
    let color: Color
    let width: CGFloat

    init(value: Double, color: Color = .accentColor, width: CGFloat = 40) {
        self.value = value
        self.color = color
        self.width = width
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.15))

                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: geo.size.width * min(value / 100, 1.0))
            }
        }
        .frame(width: width, height: 4)
    }

    private var barColor: Color {
        if value > 90 { return .red }
        if value > 70 { return .orange }
        return color
    }
}

/// Row showing a category overview in the popover.
struct OverviewRow: View {
    let icon: String
    let label: String
    let value: String
    let percent: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 60, alignment: .leading)

            UsageBar(value: percent, color: color, width: 60)

            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
