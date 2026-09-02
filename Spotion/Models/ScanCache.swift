import Foundation

struct ScanCacheEntry: Codable, Sendable {
    var mtime: Date
    var size: Int64
    /// nil = parsed but unusable (no session_meta / no cwd etc.); not retried
    /// until the file changes
    var record: SessionRecord?
}

struct ScanCache: Codable, Sendable {
    /// v7: Codex git branch; v6: later prompt preference and hydration state;
    /// v5: iconSources; v4: pendingGhostDeletions; v3: dirtyIDs;
    /// v2: head expansion
    static let currentVersion = 7

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
    /// Spotlight items that must be deleted but are tracked by neither records
    /// nor indexedIDs (ghosts from system reindex requests or late zombie
    /// mutations). Retried every refresh until the deletion lands.
    var pendingGhostDeletions: Set<String> = []
    /// codex sessionID → thread_name (from ~/.codex/session_index.jsonl)
    var codexTitles: [String: String] = [:]
    /// AgentKind.rawValue → opaque fingerprint of the icon source last folded
    /// into the dirty set (donated thumbnails embed the handler app's icon, so
    /// installing/removing/replacing that app must re-donate every session of
    /// the agent even though the session files are unchanged)
    var iconSources: [String: String] = [:]
    /// Preference fingerprint used to force exactly one reparse/re-donation
    /// when opt-in later-prompt indexing changes.
    var searchLaterPromptsEnabled = false
    /// Unchanged transcript paths still awaiting the opt-in reparse. A failed
    /// read or root enumeration leaves the path here for a later retry.
    var laterPromptPendingPaths: Set<String> = []
}

enum DonatedContentGeneration {
    /// v4 adds raw and agent-prefixed session IDs to donated keywords.
    static let current = 4

    static func requiresFullRebuild(stored: Int) -> Bool {
        stored < current
    }
}
