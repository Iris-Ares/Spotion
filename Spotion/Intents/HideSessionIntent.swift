import AppIntents

/// Removes an indexed session from Spotion without changing any Codex or
/// Claude transcript, archive state, title, or launch behavior.
struct HideSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Hide Session from Spotion"
    static let description = IntentDescription(
        "Hide a session from Spotion search and menus without deleting or archiving its source session.",
        categoryName: "Sessions"
    )

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Hide \(\.$session) from Spotion")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AppCoordinator.shared.hideSession(id: session.id)
        return .result(
            dialog: "Hidden from Spotion. The Codex or Claude source session was not changed."
        )
    }
}
