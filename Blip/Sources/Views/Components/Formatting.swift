import Foundation

enum Fmt {
    static func bytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func diskBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useTB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func speed(_ bytesPerSec: UInt64) -> String {
        if bytesPerSec > 1_000_000 {
            return String(format: "%.1f MB/s", Double(bytesPerSec) / 1_000_000)
        } else if bytesPerSec > 1_000 {
            return String(format: "%.0f KB/s", Double(bytesPerSec) / 1_000)
        }
        return "\(bytesPerSec) B/s"
    }

    /// Compact speed for overview rows
    static func shortSpeed(_ bytesPerSec: UInt64) -> String {
        if bytesPerSec > 1_000_000 {
            return String(format: "%.1fM", Double(bytesPerSec) / 1_000_000)
        } else if bytesPerSec > 1_000 {
            return String(format: "%.0fK", Double(bytesPerSec) / 1_000)
        }
        return "0K"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func temperature(_ celsius: Double) -> String {
        String(format: "%.1f°C", celsius)
    }

    static func timeRemaining(_ minutes: Int) -> String {
        guard minutes > 0 else { return "Calculating..." }
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}
