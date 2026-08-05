import AppIntents

/// Tahoe Spotlight 索引不稳时的手动保险：清空命名索引后全量重建。
struct ReindexSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Reindex Agent Sessions"
    static let description = IntentDescription(
        "Rebuild the Spotlight index of Codex and Claude Code sessions.",
        categoryName: "Maintenance"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppCoordinator.shared.fullReindex()
        let state = AppCoordinator.shared.uiState
        return .result(dialog: "已重建索引：Codex \(state.codexCount) 个、Claude Code \(state.claudeCount) 个会话")
    }
}
