import Foundation

struct ScanCacheEntry: Codable, Sendable {
    var mtime: Date
    var size: Int64
    /// nil = 解析过但不可用（无 session_meta / 无 cwd 等），文件不变则不再重试
    var record: SessionRecord?
}

struct ScanCache: Codable, Sendable {
    /// v3：新增 dirtyIDs（donate 失败重试）；v2：头窗口按需扩展
    static let currentVersion = 3

    var version: Int = currentVersion
    /// key = 会话文件绝对路径
    var entries: [String: ScanCacheEntry] = [:]
    /// 上次成功 donate 到 Spotlight 的 id 集合，用于删除 diff（跨启动持久化）
    var indexedIDs: Set<String> = []
    /// 内容已变更但尚未确认 donate 成功的 id：markIndexed 时才清除，
    /// 保证 upsert 超时/失败后下轮仍会重试（缓存 mtime 命中不再意味着可跳过）
    var dirtyIDs: Set<String> = []
    /// codex sessionID → thread_name（来自 ~/.codex/session_index.jsonl）
    var codexTitles: [String: String] = [:]
}
