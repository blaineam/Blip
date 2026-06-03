import SwiftUI

/// Displays a running process with its icon, name, and resource usage.
struct ProcessRow: View {
    let process: ProcessInfo
    let mode: Mode
    /// Optional kill handler. When provided, a quit control appears on hover.
    /// Returns the result message (nil = success, non-nil = error to surface).
    var onKill: ((pid_t, Bool) async -> (ok: Bool, message: String))? = nil
    /// The PID armed for confirm, stored persistently by the app so the two-click
    /// confirm survives the detail panel rebuilding every 2 seconds.
    var armedPID: Binding<pid_t?> = .constant(nil)

    enum Mode {
        case cpu
        case memory
    }

    @State private var hovering = false
    @State private var killing = false
    @State private var errorMessage: String?

    private var confirming: Bool { armedPID.wrappedValue == process.id }

    var body: some View {
        HStack(spacing: 6) {
            // App icon
            if let iconData = process.icon, let nsImage = NSImage(data: iconData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .cornerRadius(3)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }

            Text(process.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Surface a kill error briefly inline, otherwise show the usage value.
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                switch mode {
                case .cpu:
                    Text(String(format: "%.1f%%", process.cpu))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                case .memory:
                    Text(Fmt.bytes(process.memory))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }

            // Kill control — only when a handler is wired and on hover.
            if onKill != nil {
                killControl
                    .frame(width: 16)
                    .opacity(hovering || confirming ? 1 : 0)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
        }
    }

    @ViewBuilder
    private var killControl: some View {
        if killing {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
        } else {
            Button {
                if confirming {
                    performKill()
                } else {
                    // First click arms this PID (persisted in the app, cleared when the
                    // pointer leaves the process list).
                    armedPID.wrappedValue = process.id
                }
            } label: {
                Image(systemName: confirming ? "xmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(confirming ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(confirming ? "Click again to quit \(process.name)" : "Quit \(process.name)")
        }
    }

    private func performKill() {
        guard let onKill else { return }
        let pid = process.id
        armedPID.wrappedValue = nil
        killing = true
        errorMessage = nil
        Task {
            let result = await onKill(pid, false)
            await MainActor.run {
                killing = false
                if !result.ok {
                    errorMessage = result.message
                    // Clear the inline error after a few seconds.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        errorMessage = nil
                    }
                }
            }
        }
    }
}
