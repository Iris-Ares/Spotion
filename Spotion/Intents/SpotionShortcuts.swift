import AppIntents

/// Shortcuts / Siri 短语（Spotlight 动作不依赖它，但顺手提供）。
struct SpotionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewCodexSessionIntent(),
            phrases: ["New Codex session in \(.applicationName)"],
            shortTitle: "New Codex Session",
            systemImageName: "chevron.left.forwardslash.chevron.right"
        )
        AppShortcut(
            intent: NewClaudeSessionIntent(),
            phrases: ["New Claude session in \(.applicationName)"],
            shortTitle: "New Claude Session",
            systemImageName: "asterisk.circle"
        )
        AppShortcut(
            intent: ReindexSessionsIntent(),
            phrases: ["Reindex \(.applicationName) sessions"],
            shortTitle: "Reindex Sessions",
            systemImageName: "arrow.clockwise"
        )
    }
}
