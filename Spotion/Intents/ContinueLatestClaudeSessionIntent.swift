import AppIntents

/// Resume the newest Claude record chosen by Spotion, never by Claude's
/// implicit `--continue` selection.
struct ContinueLatestClaudeSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Latest Claude Session"
    static let description = IntentDescription(
        "Resume the latest indexed Claude Code session, optionally within a project.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Project")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Continue latest Claude session") {
            \.$project
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch try await AppCoordinator.shared.continueLatestSession(
            agent: .claude, projectCWD: project?.id
        ) {
        case .terminal(let app):
            return .result(dialog: "正在 \(app.displayName) 中恢复最新 Claude Code 会话…")
        case .nativeApp(let name):
            return .result(dialog: "正在 \(name) 中打开最新 Claude Code 会话…")
        }
    }
}
