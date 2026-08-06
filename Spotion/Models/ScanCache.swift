import Foundation

struct ScanCacheEntry: Codable, Sendable {
    var mtime: Date
    var size: Int64
    /// nil = parsed but unusable (no session_meta / no cwd etc.); not retried
    /// until the file changes
    var record: SessionRecord?
}

struct ScanCache: Codable, Sendable {
    /// v3: added dirtyIDs (donation-failure retry); v2: on-demand head expansion
    static let currentVersion = 3

    var version: Int = currentVersion
    /// key = absolute session file path
    var entries: [String: ScanCacheEntry] = [:]
    /// Ids last successfully donated to Spotlight, used for the deletion diff
    /// (persisted across launches)
    var indexedIDs: Set<String> = []
    /// Ids whose content changed but whose donation has not been confirmed yet:
    /// cleared only in markIndexed, so a timed-out/failed upsert retries next
    /// cycle (an mtime cache hit no longer implies the id can be skipped)
    var dirtyIDs: Set<String> = []
    /// codex sessionID → thread_name (from ~/.codex/session_index.jsonl)
    var codexTitles: [String: String] = [:]
}
