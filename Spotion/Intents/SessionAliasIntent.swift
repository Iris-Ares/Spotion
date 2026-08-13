import AppIntents

struct SetSessionAliasIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Spotion Session Alias"
    static let description = IntentDescription(
        "Set a local Spotion-only name without changing the Codex or Claude session.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Spotion Alias")
    var alias: String

    static var parameterSummary: some ParameterSummary {
        Summary("Set alias for \(\.$session) to \(\.$alias)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AppCoordinator.shared.setSessionAlias(id: session.id, alias: alias)
        return .result(dialog: "Set a Spotion-only alias for \(session.sourceTitle).")
    }
}

struct ClearSessionAliasIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Spotion Session Alias"
    static let description = IntentDescription(
        "Clear a local Spotion alias and restore the current Codex or Claude title.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Clear alias for \(\.$session)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AppCoordinator.shared.clearSessionAlias(id: session.id)
        return .result(dialog: "Cleared the Spotion-only alias for \(session.sourceTitle).")
    }
}
