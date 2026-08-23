import Foundation

// Hardware identifier → marketing name. Covers the era Blip 2.0 ships into; unknown ids fall
// back to the codename (never guess). Extend as devices appear — the table IS the feature.
enum DeviceNames {
    static func name(for identifier: String) -> String {
        if identifier == "arm64" || identifier.hasPrefix("x86") {
            // Simulator reports the HOST architecture.
            return "Simulator (\(identifier))"
        }
        return table[identifier] ?? identifier
    }

    private static let table: [String: String] = [
        // iPhone 14 family
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        // iPhone 15 family
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        // iPhone 16 family
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        // iPhone 17 family
        "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,4": "iPhone Air",
        // Recent iPads (broad strokes; unknowns show the codename)
        "iPad14,3": "iPad Pro 11\" (M2)", "iPad14,4": "iPad Pro 11\" (M2)",
        "iPad14,5": "iPad Pro 12.9\" (M2)", "iPad14,6": "iPad Pro 12.9\" (M2)",
        "iPad16,3": "iPad Pro 11\" (M4)", "iPad16,4": "iPad Pro 11\" (M4)",
        "iPad16,5": "iPad Pro 13\" (M4)", "iPad16,6": "iPad Pro 13\" (M4)",
        "iPad14,8": "iPad Air 11\" (M2)", "iPad14,9": "iPad Air 11\" (M2)",
        "iPad14,10": "iPad Air 13\" (M2)", "iPad14,11": "iPad Air 13\" (M2)",
        "iPad15,3": "iPad Air 11\" (M3)", "iPad15,4": "iPad Air 11\" (M3)",
        "iPad15,5": "iPad Air 13\" (M3)", "iPad15,6": "iPad Air 13\" (M3)",
    ]
}
