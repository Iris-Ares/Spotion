import AppIntents

/// Spotlight 会话结果的打开动作：在终端中以正确 cwd resume。
struct OpenSessionIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Agent Session"
    static let description = IntentDescription(
        "Resume a Codex or Claude Code session in your terminal.",
        categoryName: "Sessions"
    )

    @Parameter(title: "Session")
    var target: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AppCoordinator.shared.openSession(id: target.id)
        return .result(dialog: "正在 \(SpotionSettings.terminal.displayName) 中恢复会话…")
    }
}
