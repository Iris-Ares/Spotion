import Foundation

struct SessionRecord: Codable, Sendable, Identifiable, Hashable {
    /// Stable Spotlight identifier: "codex:<uuid>" / "claude:<uuid>"
    var id: String
    var agent: AgentKind
    /// Raw session id passed to `codex resume` / `claude --resume`
    var sessionID: String
    /// claude: title parsed from the tail title records; always nil for codex
    /// (codex titles live in session_index.jsonl)
    var fallbackTitle: String?
    /// First real user input (truncated to ~300 characters)
    var firstPrompt: String?
    var cwd: String
    var projectName: String
    var gitBranch: String?
    var startedAt: Date?
    /// File mtime
    var lastActivityAt: Date
    var filePath: String
    var fileSize: Int64

    static func makeID(agent: AgentKind, sessionID: String) -> String {
        "\(agent.rawValue):\(sessionID)"
    }
}

extension String {
    /// Collapsed to a single line, whitespace-folded and truncated — used as
    /// the Spotlight title.
    var titleSanitized: String {
        let collapsed = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(100))
    }
}
