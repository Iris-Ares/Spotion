import AppIntents

/// Manual safety valve for Tahoe's Spotlight indexing flakiness: wipe the named
/// index and rebuild from scratch.
struct ReindexSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Reindex Agent Sessions"
    static let description = IntentDescription(
        "Rebuild the Spotlight index of Codex and Claude Code sessions.",
        categoryName: "Maintenance"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // fullReindex reports whether deleteAll actually succeeded — the user
        // ran this to repair a broken index, so a failed wipe must not be
        // announced as a successful rebuild.
        let cleaned = await AppCoordinator.shared.fullReindex()
        let state = AppCoordinator.shared.uiState
        if cleaned {
            return .result(dialog: "已重建索引：Codex \(state.codexCount) 个、Claude Code \(state.claudeCount) 个会话")
        }
        let reason = state.lastError ?? "索引服务无响应"
        return .result(dialog: "重建未完成：清空旧索引失败（\(reason)）。本次已改为增量刷新，完整重建将在下次启动自动重试。")
    }
}
