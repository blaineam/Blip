import SwiftUI

/// Displays a running process with its icon, name, and resource usage.
struct ProcessRow: View {
    let process: ProcessInfo
    let mode: Mode

    enum Mode {
        case cpu
        case memory
    }

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
        .padding(.vertical, 1)
    }
}
