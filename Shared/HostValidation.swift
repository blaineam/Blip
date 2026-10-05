import Foundation

/// Validates a traceroute / ping target before it's handed to a subprocess or
/// socket. Shared by the local traceroute runner, the Settings validation, and
/// the App Intents layer. Hostnames, IPv4, and IPv6 literals are accepted;
/// anything with shell-meaningful or whitespace characters (or a leading "-") is rejected.
enum HostValidation {
    static func isValid(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        // The host is the last argv element of /usr/sbin/traceroute; a leading "-" would
        // be parsed as an option. No hostname or IP literal starts with one.
        guard !host.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
