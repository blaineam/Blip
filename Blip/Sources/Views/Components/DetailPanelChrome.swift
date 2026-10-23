import SwiftUI

/// Wraps a section's detail panel with a pin in its top corner. Pinning tears
/// the panel off into its own floating window (see AppDelegate.pinPanel);
/// the pin on that window closes it again.
struct DetailPanelChrome<Content: View>: View {
    let pinned: Bool
    /// UI-test handle: the panel is the `detail.<section>` container.
    var section: String = ""
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
        // A panel's brand wash (Bench) is painted here, behind the pin strip too, so it
        // reaches the panel's top edge instead of starting in a seam below the strip.
        .paintsPanelWash()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.\(section)")
    }
}

// MARK: - Panel wash

/// A full-bleed brand wash a detail panel asks its host to paint behind the WHOLE panel,
/// chrome strip included. Painting it inside the panel stopped it short of the top edge
/// (field-caught: the Bench gradient began under the pin strip, leaving a lighter band
/// across the top of the panel).
struct PanelWash: Equatable, Sendable {
    var colors: [Color]
    var start: UnitPoint = .topLeading
    var end: UnitPoint = .bottomTrailing

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: start, endPoint: end)
    }
}

struct PanelWashKey: PreferenceKey {
    static let defaultValue: PanelWash? = nil
    static func reduce(value: inout PanelWash?, nextValue: () -> PanelWash?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Asks the enclosing panel host to paint `wash` behind everything it wraps.
    func panelWash(_ wash: PanelWash) -> some View {
        preference(key: PanelWashKey.self, value: wash)
    }

    /// Paints the wash a wrapped panel asked for, edge to edge behind this view.
    func paintsPanelWash() -> some View {
        backgroundPreferenceValue(PanelWashKey.self) { wash in
            if let wash { wash.gradient }
        }
    }
}
