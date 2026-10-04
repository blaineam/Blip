import SwiftUI

/// Whether the closed-lid and jiggle extras can be offered: always in the
/// direct download, only while Blip Helper is connected in the App Store build.
@MainActor
func keepAwakeExtrasAvailable(_ monitor: SystemMonitor?) -> Bool {
    #if APPSTORE
    return monitor?.helperClient.isConnected ?? false
    #else
    return true
    #endif
}

/// Popover row on exactly the same grid as CPU/Memory/…: icon (16), label
/// (60), the switch where the others draw their bar (60), the time left in
/// the value column (40), and the chevron to the hover panel.
struct KeepAwakeOverviewRow: View {
    @ObservedObject var keepAwake: KeepAwake

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 8) {
                Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(keepAwake.isActive ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 16)

                Text("Awake")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 60, alignment: .leading)

                PillSwitch(isOn: Binding(
                    get: { keepAwake.isActive },
                    set: { _ in keepAwake.toggle() }
                ), label: "Keep Mac Awake")
                .help(keepAwake.isActive ? "Let the Mac sleep" : "Keep the Mac awake (\(keepAwake.lastDuration.title))")
                .frame(width: 60, alignment: .leading)

                Text(valueText(at: context.date))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(keepAwake.isActive ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 40, alignment: .trailing)

                RowChevron()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
    }

    private func valueText(at date: Date) -> String {
        guard keepAwake.isActive else { return String(localized: "Off") }
        guard let endsAt = keepAwake.endsAt else { return "∞" }
        let minutes = max(0, Int(endsAt.timeIntervalSince(date) / 60.0 + 0.999))
        return minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)m"
    }
}

/// The hover panel: status, how long, and the display / lid / mouse options.
struct KeepAwakeDetailPanel: View {
    @ObservedObject var keepAwake: KeepAwake
    let extrasAvailable: Bool
    @AppStorage(KeepAwake.Keys.keepDisplayOn) private var keepDisplayOn = true
    @AppStorage(KeepAwake.Keys.lidClosed) private var lidClosed = false
    @AppStorage(KeepAwake.Keys.jiggle) private var jiggle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(.orange)
                Text("Keep Awake")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                statusText
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(keepAwake.isActive ? .orange : .secondary)
            }

            Text("Stops this Mac from going to sleep, for a while or until you turn it off.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            durationGrid

            if keepAwake.isActive {
                Button {
                    keepAwake.stop()
                } label: {
                    Label("Let Mac Sleep", systemImage: "moon.zzz")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }

            Divider()

            option("Keep the display on", isOn: $keepDisplayOn,
                   detail: "Off lets the screen dim and sleep while the Mac keeps running.")

            if extrasAvailable {
                option("Stay awake with the lid closed", isOn: $lidClosed,
                       detail: "Asks for an administrator password. Normal sleep returns when Keep Awake ends, Blip quits, or the battery reaches 10%.")
                option("Jiggle the mouse when idle", isOn: $jiggle,
                       detail: "After a minute without input, the pointer moves one pixel and back so apps don't mark you away.")
            }

            statusLine
        }
        .padding(12)
        .onAppear { keepAwake.refreshExtras() }
    }

    @ViewBuilder
    private var statusText: some View {
        if !keepAwake.isActive {
            Text("Off")
        } else if let endsAt = keepAwake.endsAt {
            Text("Until \(endsAt.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("On")
        }
    }

    /// One row of equal chips; the running one is filled.
    private var durationGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: KeepAwakeDuration.allCases.count)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(KeepAwakeDuration.allCases, id: \.self) { duration in
                let selected = keepAwake.isActive && keepAwake.lastDuration == duration
                Button {
                    keepAwake.start(duration)
                } label: {
                    Text(duration.shortTitle)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Color.orange.opacity(0.85) : Color.primary.opacity(0.07))
                        )
                        .foregroundStyle(selected ? .white : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(duration.title)
            }
        }
    }

    private func option(_ title: LocalizedStringKey, isOn: Binding<Bool>, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                PillSwitch(isOn: isOn, label: title)
            }
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let notice = keepAwake.notice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if keepAwake.extras.lidPending {
            Label("Waiting for your administrator password…", systemImage: "lock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if extrasAvailable && jiggle && !keepAwake.extras.jigglePermission {
            HStack {
                Label("Jiggling needs Accessibility access", systemImage: "hand.raised")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Allow…") { keepAwake.requestJigglePermission() }
                    .controlSize(.mini)
            }
        }
    }
}

/// Settings → General → Keep Awake.
struct KeepAwakeSettingsSection: View {
    @ObservedObject var keepAwake: KeepAwake
    let extrasAvailable: Bool
    @AppStorage(KeepAwake.Keys.keepDisplayOn) private var keepDisplayOn = true
    @AppStorage(KeepAwake.Keys.lidClosed) private var lidClosed = false
    @AppStorage(KeepAwake.Keys.jiggle) private var jiggle = false
    @AppStorage(KeepAwake.Keys.menuBarIndicator) private var menuBarIndicator = true

    var body: some View {
        Section("Keep Awake") {
            Toggle("Keep the display on", isOn: $keepDisplayOn)
            Toggle("Show a cup in the menu bar while awake", isOn: $menuBarIndicator)
            if extrasAvailable {
                Toggle("Stay awake with the lid closed", isOn: $lidClosed)
                Toggle("Jiggle the mouse when idle", isOn: $jiggle)
                if jiggle && !keepAwake.extras.jigglePermission {
                    HStack {
                        Text("Jiggling needs Accessibility access")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Allow…") { keepAwake.requestJigglePermission() }
                    }
                }
            }
            Text("Turn Keep Awake on from the Awake row in Blip's menu. Lid-closed mode asks for an administrator password once while Blip is running, and ends when Keep Awake does, when Blip quits, or at 10% battery.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { keepAwake.refreshExtras() }
    }
}

/// A compact on/off switch that stays legible in Blip's non-activating
/// popover and panels, where the system switch renders desaturated and on
/// looks the same as off.
struct PillSwitch: View {
    @Binding var isOn: Bool
    let label: LocalizedStringKey

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? Color.orange : Color.primary.opacity(0.18))
                .frame(width: 26, height: 15)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
    }
}
