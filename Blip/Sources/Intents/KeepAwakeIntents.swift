import AppIntents

// MARK: - Keep Awake intents

extension KeepAwakeDuration: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Keep Awake Duration"
    static let caseDisplayRepresentations: [KeepAwakeDuration: DisplayRepresentation] = [
        .thirtyMinutes: "30 Minutes",
        .oneHour: "1 Hour",
        .twoHours: "2 Hours",
        .fourHours: "4 Hours",
        .indefinitely: "Until Turned Off",
    ]
}

struct KeepMacAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Mac Awake"
    static let description = IntentDescription(
        "Stops your Mac from going to sleep for a while, or until you turn it off. Uses the display, lid and mouse settings from Blip's menu.",
        categoryName: "Keep Awake"
    )

    @Parameter(title: "Duration", default: .indefinitely)
    var duration: KeepAwakeDuration

    static var parameterSummary: some ParameterSummary {
        Summary("Keep Mac awake for \(\.$duration)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let keepAwake = AppIntentsEnvironment.keepAwake
        keepAwake.start(duration)
        if let endsAt = keepAwake.endsAt {
            return .result(dialog: "Your Mac will stay awake until \(endsAt.formatted(date: .omitted, time: .shortened)).")
        }
        return .result(dialog: "Your Mac will stay awake until you turn Keep Awake off.")
    }
}

struct LetMacSleepIntent: AppIntent {
    static let title: LocalizedStringResource = "Let Mac Sleep"
    static let description = IntentDescription(
        "Turns Keep Awake off so your Mac sleeps normally again.",
        categoryName: "Keep Awake"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentsEnvironment.keepAwake.stop()
        return .result(dialog: "Your Mac can sleep normally again.")
    }
}
