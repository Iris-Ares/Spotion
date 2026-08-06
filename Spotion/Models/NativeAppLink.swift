import Foundation

/// Deep links into the agents' desktop apps.
/// codex://threads/<uuid> — the same URL the codex CLI's own "open in app"
/// feature emits; the thread id is the session uuid `codex resume` takes.
/// claude://resume?session=<uuid> — Claude desktop locates the local CLI
/// transcript by uuid and imports it into its Claude Code UI.
enum NativeAppLink {
    /// nil when sessionID is not a canonical UUID — a deep link must not carry
    /// arbitrary strings into another app (both handlers validate UUIDs too).
    static func url(agent: AgentKind, sessionID: String) -> URL? {
        // Validation only; keep the caller's spelling (no case normalization)
        guard UUID(uuidString: sessionID) != nil else { return nil }
        return switch agent {
        case .codex: URL(string: "codex://threads/\(sessionID)")
        case .claude: URL(string: "claude://resume?session=\(sessionID)")
        }
    }

    /// Scheme-only URL for the LaunchServices handler lookup.
    static func probeURL(for agent: AgentKind) -> URL {
        URL(string: "\(scheme(for: agent))://")!
    }

    /// Spelled out rather than derived from agent.rawValue — that equality is
    /// coincidental.
    static func scheme(for agent: AgentKind) -> String {
        switch agent {
        case .codex: "codex"
        case .claude: "claude"
        }
    }

    /// Which app to install, for error messages.
    static func appHint(for agent: AgentKind) -> String {
        switch agent {
        case .codex: "Codex（ChatGPT）桌面版"
        case .claude: "Claude 桌面版"
        }
    }
}
