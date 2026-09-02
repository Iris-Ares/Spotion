import Foundation

/// User-facing errors shared by the store, the coordinator, and App Intents.
/// Lives in Models so the hostless test target can see it.
enum SpotionError: LocalizedError, Sendable {
    case sessionNotFound(String)
    case noMatchingSession(agent: AgentKind, projectCWD: String?)
    /// Spotion's own state was persisted, but the Spotlight mutation did not
    /// confirm; the durable dirty/indexed pipeline retries it.
    case indexMutationPending(String)
    case hiddenSessionSourceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id): "会话已不存在：\(id)"
        case .noMatchingSession(let agent, let projectCWD):
            if let projectCWD {
                "未找到 \(agent.displayName) 在 \((projectCWD as NSString).lastPathComponent) 中的会话。"
            } else {
                "未找到可继续的 \(agent.displayName) 会话。"
            }
        case .indexMutationPending(let action):
            "\(action) 已安全记录，但 Spotlight 尚未确认更新；Spotion 会在下次刷新和重启后继续重试。"
        case .hiddenSessionSourceUnavailable(let id):
            "该隐藏会话的源文件当前不可用，暂时无法恢复：\(id)"
        }
    }
}
