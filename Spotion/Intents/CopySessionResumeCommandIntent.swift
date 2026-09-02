import AppIntents

/// Copies the exact CLI command without launching a terminal, native app, or
/// agent subprocess. Command construction is shared with TerminalLauncher.
struct CopySessionResumeCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Session Resume Command"
    static let description = IntentDescription(
        "Copy the exact Codex or Claude Code resume command without running it.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var target: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Copy resume command for \(\.$target)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let copied = try await AppCoordinator.shared.copySessionResumeCommand(id: target.id)
        return .result(
            dialog: "Copied \(copied.agent.displayName) resume command for \(copied.projectName)."
        )
    }
}
