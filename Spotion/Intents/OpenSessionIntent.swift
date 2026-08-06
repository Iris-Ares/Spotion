import AppIntents

/// Open action for Spotlight session results: resume in a terminal with the
/// correct cwd.
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
