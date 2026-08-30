import AppIntents
import Foundation

// MARK: - Setting catalog (curated)
//
// Only settings that are safe and meaningful to script are exposed. The
// catalog carries an `isSecret` flag and GetSetting refuses to read
// secret-flagged settings — Blip has no secrets today, but the gate is
// structural so future sensitive settings are never exposed by accident.
// Deliberately NOT exposed: launchAtLogin (toggling the default alone
// wouldn't (de)register the SMAppService — it would silently lie).

struct BlipSettingDescriptor: Sendable {
    enum Kind: Sendable {
        case boolean
        /// Free-form string; `validate` returns an error message or nil.
        case string(validate: @Sendable (String) -> String?)
        /// One of a fixed set of values.
        case choice(allowed: [String])
    }

    let key: String          // UserDefaults key (also the entity id)
    let title: String
    let kind: Kind
    let defaultValue: String // what an unset key reads as
    let isSecret: Bool

    static let hostValidator: @Sendable (String) -> String? = { value in
        if value.isEmpty { return nil }  // empty clears the target
        return HostValidation.isValid(value) ? nil : "must be a hostname or IP address"
    }

    static let urlValidator: @Sendable (String) -> String? = { value in
        if value.isEmpty { return nil }  // empty reverts to the public test
        let server = SpeedTestServer.openSpeedTest(baseURL: value)
        return server.openSpeedTestBase == nil ? "must be a server address like http://192.168.1.50:3000" : nil
    }

    static let catalog: [BlipSettingDescriptor] = [
        .init(key: "showCPU", title: "Show CPU in Menu Bar", kind: .boolean, defaultValue: "true", isSecret: false),
        .init(key: "showMemory", title: "Show Memory in Menu Bar", kind: .boolean, defaultValue: "true", isSecret: false),
        .init(key: "showDisk", title: "Show Disk in Menu Bar", kind: .boolean, defaultValue: "true", isSecret: false),
        .init(key: "showNetworkDot", title: "Show Network Dot in Menu Bar", kind: .boolean, defaultValue: "true", isSecret: false),
        .init(key: "showGPU", title: "Show GPU in Menu Bar", kind: .boolean, defaultValue: "false", isSecret: false),
        .init(key: "showMeasurementLabels", title: "Show Measurement Labels", kind: .boolean, defaultValue: "true", isSecret: false),
        .init(key: "showValueLabels", title: "Show Value Labels", kind: .boolean, defaultValue: "true", isSecret: false),
        .init(key: "colorizeUtilization", title: "Colorize Utilization", kind: .boolean, defaultValue: "true", isSecret: false),
        .init(key: "showRecommendations", title: "Show Recommendations", kind: .boolean, defaultValue: "true", isSecret: false),
        .init(key: "menuBarLayout", title: "Menu Bar Style", kind: .choice(allowed: ["horizontal", "stacked"]), defaultValue: "horizontal", isSecret: false),
        .init(key: "pingTarget", title: "Ping Target", kind: .string(validate: hostValidator), defaultValue: "1.1.1.1", isSecret: false),
        .init(key: "tracerouteTarget", title: "Traceroute Target", kind: .string(validate: hostValidator), defaultValue: "", isSecret: false),
        .init(key: "speedTestOpenSpeedTestURL", title: "Self-Hosted Speed Test Server", kind: .string(validate: urlValidator), defaultValue: "", isSecret: false),
        .init(key: "geoipAutoUpdate", title: "Auto-Update Location Database", kind: .boolean, defaultValue: "false", isSecret: false),
        // SECRETS RULE: anything marked isSecret: true is settable but never
        // gettable through Shortcuts. (No secret settings exist yet.)
    ]

    static func descriptor(for key: String) -> BlipSettingDescriptor? {
        catalog.first { $0.key == key }
    }
}

/// Pure read/write/validate logic over a defaults store — unit-tested with a
/// scratch suite, used by both intents.
enum SettingsStore {
    static func read(_ descriptor: BlipSettingDescriptor, from defaults: UserDefaults) -> String {
        switch descriptor.kind {
        case .boolean:
            if let b = defaults.object(forKey: descriptor.key) as? Bool {
                return b ? "true" : "false"
            }
            return descriptor.defaultValue
        case .string, .choice:
            return defaults.string(forKey: descriptor.key) ?? descriptor.defaultValue
        }
    }

    enum Normalization: Equatable {
        case value(String)
        case error(String)
    }

    /// Validates + normalizes a raw value. Returns the normalized value to
    /// store, or an error message.
    static func normalize(_ raw: String, for descriptor: BlipSettingDescriptor) -> Normalization {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch descriptor.kind {
        case .boolean:
            guard let b = parseBool(value) else {
                return .error("must be true or false")
            }
            return .value(b ? "true" : "false")
        case .string(let validate):
            if let error = validate(value) { return .error(error) }
            return .value(value)
        case .choice(let allowed):
            let lower = value.lowercased()
            guard allowed.contains(lower) else {
                return .error("must be one of: \(allowed.joined(separator: ", "))")
            }
            return .value(lower)
        }
    }

    static func write(_ normalized: String, for descriptor: BlipSettingDescriptor, to defaults: UserDefaults) {
        switch descriptor.kind {
        case .boolean:
            defaults.set(normalized == "true", forKey: descriptor.key)
        case .string, .choice:
            defaults.set(normalized, forKey: descriptor.key)
        }
    }

    static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }
}

// MARK: - Entity

struct SettingEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Blip Setting")
    static let defaultQuery = SettingEntityQuery()

    var id: String

    @Property(title: "Name")
    var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "gearshape"))
    }

    init(descriptor: BlipSettingDescriptor) {
        self.id = descriptor.key
        self.title = descriptor.title
    }
}

struct SettingEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SettingEntity] {
        identifiers.compactMap { BlipSettingDescriptor.descriptor(for: $0).map(SettingEntity.init) }
    }

    func suggestedEntities() async throws -> [SettingEntity] {
        BlipSettingDescriptor.catalog.map(SettingEntity.init)
    }

    func entities(matching string: String) async throws -> [SettingEntity] {
        BlipSettingDescriptor.catalog
            .filter { $0.title.localizedCaseInsensitiveContains(string) }
            .map(SettingEntity.init)
    }
}

// MARK: - Errors

enum SettingIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unknownSetting
    case secretNotReadable
    case invalidValue(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unknownSetting:
            return "That setting doesn't exist."
        case .secretNotReadable:
            return "That setting is private and can't be read from Shortcuts."
        case .invalidValue(let detail):
            return "That value isn't valid: \(detail)."
        }
    }
}

// MARK: - Get

struct GetSettingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Blip Setting"
    static let description = IntentDescription(
        "Reads one of Blip's settings, like the ping target or a menu-bar toggle.",
        categoryName: "Settings"
    )

    @Parameter(title: "Setting")
    var setting: SettingEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$setting)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let descriptor = BlipSettingDescriptor.descriptor(for: setting.id) else {
            throw SettingIntentError.unknownSetting
        }
        guard !descriptor.isSecret else { throw SettingIntentError.secretNotReadable }
        let value = SettingsStore.read(descriptor, from: AppIntentsEnvironment.defaults)
        let shown = value.isEmpty ? "(not set)" : value
        return .result(value: value, dialog: "\(descriptor.title): \(shown)")
    }
}

// MARK: - Set

struct SetSettingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Blip Setting"
    static let description = IntentDescription(
        "Changes one of Blip's settings. Booleans accept true/false, choices must match an allowed value, and host/URL settings are validated.",
        categoryName: "Settings"
    )

    @Parameter(title: "Setting")
    var setting: SettingEntity

    @Parameter(title: "Value")
    var value: String

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$setting) to \(\.$value)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let descriptor = BlipSettingDescriptor.descriptor(for: setting.id) else {
            throw SettingIntentError.unknownSetting
        }
        switch SettingsStore.normalize(value, for: descriptor) {
        case .error(let message):
            throw SettingIntentError.invalidValue(message)
        case .value(let normalized):
            SettingsStore.write(normalized, for: descriptor, to: AppIntentsEnvironment.defaults)
            let shown = normalized.isEmpty ? "(not set)" : normalized
            return .result(dialog: "\(descriptor.title) is now \(shown).")
        }
    }
}
