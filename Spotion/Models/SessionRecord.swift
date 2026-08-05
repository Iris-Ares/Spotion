import Foundation

struct SessionRecord: Codable, Sendable, Identifiable, Hashable {
    /// Spotlight 稳定标识符："codex:<uuid>" / "claude:<uuid>"
    var id: String
    var agent: AgentKind
    /// 传给 `codex resume` / `claude --resume` 的原始会话 id
    var sessionID: String
    /// claude：从文件尾部 title 记录解析出的标题；codex 恒为 nil（标题在 session_index.jsonl）
    var fallbackTitle: String?
    /// 首个真实用户输入（截断 ~300 字符）
    var firstPrompt: String?
    var cwd: String
    var projectName: String
    var gitBranch: String?
    var startedAt: Date?
    /// 文件 mtime
    var lastActivityAt: Date
    var filePath: String
    var fileSize: Int64

    static func makeID(agent: AgentKind, sessionID: String) -> String {
        "\(agent.rawValue):\(sessionID)"
    }
}

extension String {
    /// 压成单行、折叠空白、截断，用作 Spotlight 标题
    var titleSanitized: String {
        let collapsed = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(100))
    }
}
