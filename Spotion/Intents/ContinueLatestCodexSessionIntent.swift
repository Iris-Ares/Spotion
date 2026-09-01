import AppIntents

/// Resume the newest Codex record chosen by Spotion, never by an implicit CLI
/// `--last` selection. The optional project reuses the existing ProjectEntity.
struct ContinueLatestCodexSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Latest Codex Session"
    static let description = IntentDescription(
        "Resume the latest indexed Codex session, optionally within a project.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Project")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Continue latest Codex session") {
            \.$project
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch try await AppCoordinator.shared.continueLatestSession(
            agent: .codex, projectCWD: project?.id
        ) {
        case .terminal(let app):
            return .result(dialog: "正在 \(app.displayName) 中恢复最新 Codex 会话…")
        case .nativeApp(let name):
            return .result(dialog: "正在 \(name) 中打开最新 Codex 会话…")
        }
    }
}
