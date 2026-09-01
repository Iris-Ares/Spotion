import AppIntents

/// Fork an exact indexed session without mutating or resuming its source.
/// This stays terminal-only until the native apps publish an equivalent
/// explicit fork deep-link contract.
struct ForkSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Fork Agent Session"
    static let description = IntentDescription(
        "Fork a Codex or Claude Code session in your configured terminal.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var target: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Fork \(\.$target)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let terminal = try await AppCoordinator.shared.forkSession(id: target.id)
        return .result(dialog: "正在 \(terminal.displayName) 中派生新会话…")
    }
}
