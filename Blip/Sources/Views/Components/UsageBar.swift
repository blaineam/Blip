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
    /// UI-test handle: the label is `popover.row.<id>`, the value `popover.row.<id>.value`.
    var id: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16)

            // LocalizedStringKey: `label` arrives as a variable, and Text(String)
            // renders it verbatim — this is what routes "CPU"/"Memory"/… through
            // the string catalog.
            Text(LocalizedStringKey(label))
                .font(.system(size: 11, weight: .medium))
                .frame(width: 60, alignment: .leading)
                .accessibilityIdentifier("popover.row.\(id)")

            UsageBar(value: percent, color: color, width: 60)

            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .accessibilityIdentifier("popover.row.\(id).value")

            RowChevron()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

/// Where a section's details appear: the hover panel beside the popover
/// (default), or expanded inline under its row on click.
enum DetailPanelStyle: String, CaseIterable {
    case beside, inline

    static let key = "detailPanelStyle"

    static var current: DetailPanelStyle {
        UserDefaults.standard.string(forKey: key).flatMap(DetailPanelStyle.init(rawValue:)) ?? .beside
    }
}

private struct RowExpandedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True on a popover row whose details are expanded inline.
    var rowExpanded: Bool {
        get { self[RowExpandedKey.self] }
        set { self[RowExpandedKey.self] = newValue }
    }
}

/// The trailing chevron on popover rows; turns down when the row is expanded inline.
struct RowChevron: View {
    @Environment(\.rowExpanded) private var expanded

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8))
            .foregroundStyle(.quaternary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }
}
