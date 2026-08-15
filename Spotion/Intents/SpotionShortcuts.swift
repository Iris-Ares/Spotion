import AppIntents

/// Shortcuts / Siri phrases (Spotlight actions do not depend on this, but it
/// is cheap to provide).
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
        AppShortcut(
            intent: CopySessionResumeCommandIntent(),
            phrases: ["Copy a session resume command in \(.applicationName)"],
            shortTitle: "Copy Resume Command",
            systemImageName: "doc.on.clipboard"
        )
    }
}
