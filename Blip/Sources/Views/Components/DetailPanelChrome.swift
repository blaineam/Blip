import SwiftUI

/// Wraps a section's detail panel with a pin in its top corner. Pinning tears
/// the panel off into its own floating window (see AppDelegate.pinPanel);
/// the pin on that window closes it again.
struct DetailPanelChrome<Content: View>: View {
    let pinned: Bool
    let onTogglePin: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onTogglePin) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(pinned ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .frame(width: 20, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pinned ? "Unpin — close this panel" : "Pin this panel open in its own window")
                .accessibilityLabel(Text(pinned ? "Unpin Panel" : "Pin Panel"))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            // Panels carry their own 12 pt top padding; tuck it under the strip.
            content
                .padding(.top, -8)
        }
    }
}
