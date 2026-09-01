import AppIntents

/// Shortcuts / Siri phrases (Spotlight actions do not depend on this, but it
/// is cheap to provide). macOS allows at most 10 App Shortcuts per app and
/// this list is at the cap; further intents (fork, copy command, resume from
/// PR…) stay reachable through Spotlight and the Shortcuts app without a
/// Siri phrase.
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
            intent: ContinueLatestCodexSessionIntent(),
            phrases: ["Continue the latest Codex session in \(.applicationName)"],
            shortTitle: "Continue Latest Codex",
            systemImageName: "chevron.left.forwardslash.chevron.right"
        )
        AppShortcut(
            intent: ContinueLatestClaudeSessionIntent(),
            phrases: ["Continue the latest Claude session in \(.applicationName)"],
            shortTitle: "Continue Latest Claude",
            systemImageName: "asterisk.circle"
        )
        AppShortcut(
            intent: HideSessionIntent(),
            phrases: ["Hide a session from \(.applicationName)"],
            shortTitle: "Hide Session",
            systemImageName: "eye.slash"
        )
        AppShortcut(
            intent: PinSessionIntent(),
            phrases: ["Pin a session in \(.applicationName)"],
            shortTitle: "Pin Session",
            systemImageName: "pin"
        )
        AppShortcut(
            intent: UnpinSessionIntent(),
            phrases: ["Unpin a session in \(.applicationName)"],
            shortTitle: "Unpin Session",
            systemImageName: "pin.slash"
        )
        AppShortcut(
            intent: SetSessionAliasIntent(),
            phrases: ["Set a session alias in \(.applicationName)"],
            shortTitle: "Set Session Alias",
            systemImageName: "pencil"
        )
        AppShortcut(
            intent: ClearSessionAliasIntent(),
            phrases: ["Clear a session alias in \(.applicationName)"],
            shortTitle: "Clear Session Alias",
            systemImageName: "pencil.slash"
        )
    }
}
