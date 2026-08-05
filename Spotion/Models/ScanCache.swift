import Foundation

struct ScanCacheEntry: Codable, Sendable {
    var mtime: Date
    var size: Int64
    /// nil = 解析过但不可用（无 session_meta / 无 cwd 等），文件不变则不再重试
    var record: SessionRecord?
}

struct ScanCache: Codable, Sendable {
    /// v2：头窗口按需扩展修复了巨型首行导致的解析失败——升版强制全量重解析
    static let currentVersion = 2

    var version: Int = currentVersion
    /// key = 会话文件绝对路径
    var entries: [String: ScanCacheEntry] = [:]
    /// 上次成功 donate 到 Spotlight 的 id 集合，用于删除 diff（跨启动持久化）
    var indexedIDs: Set<String> = []
    /// codex sessionID → thread_name（来自 ~/.codex/session_index.jsonl）
    var codexTitles: [String: String] = [:]
}
