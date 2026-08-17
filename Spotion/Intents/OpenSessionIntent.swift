import AppIntents

/// Open action for Spotlight session results: resume in a terminal with the
/// correct cwd, or hand off to the agent's desktop app, per the
/// settings-selected launch target.
struct OpenSessionIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Agent Session"
    static let description = IntentDescription(
        "Resume a Codex or Claude Code session in your terminal or its desktop app.",
        categoryName: "Sessions"
    )

    @Parameter(title: "Session")
    var target: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let coordinator = await AppCoordinator.shared
        let archived = await coordinator.isArchivedSession(id: target.id)
        if archived {
            try await requestConfirmation(
                actionName: .continue,
                dialog: "This session is archived. Unarchive it with Codex, then open it?"
            )
        }
        switch try await coordinator.openSession(id: target.id, archivedConfirmed: archived) {
        case .terminal(let app):
            return .result(dialog: "正在 \(app.displayName) 中恢复会话…")
        case .nativeApp(let name):
            return .result(dialog: "正在 \(name) 中打开会话…")
        }
    }
}
