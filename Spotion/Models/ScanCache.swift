import Foundation

struct ScanCacheEntry: Codable, Sendable {
    var mtime: Date
    var size: Int64
    /// nil = parsed but unusable (no session_meta / no cwd etc.); not retried
    /// until the file changes
    var record: SessionRecord?
}

struct ScanCache: Codable, Sendable {
    /// v6: later prompt preference and hydration state; v5: iconSources;
    /// v4: pendingGhostDeletions; v3: dirtyIDs; v2: head expansion
    static let currentVersion = 6

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
    /// 0 means touched-file indexing is disabled. A positive generation
    /// changes when allowlisted tool schemas or normalization behavior changes.
    var touchedFileExtractionGeneration = 0
    /// Unchanged transcript paths awaiting bounded touched-file hydration.
    var touchedFilePendingPaths: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case version, entries, indexedIDs, dirtyIDs, pendingGhostDeletions
        case codexTitles, iconSources, searchLaterPromptsEnabled
        case laterPromptPendingPaths, touchedFileExtractionGeneration
        case touchedFilePendingPaths
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve the existing fail-closed cache contract: all v6 fields stay
        // required, while only the new touched-file fields default for a valid
        // pre-feature v6 cache.
        version = try values.decode(Int.self, forKey: .version)
        entries = try values.decode([String: ScanCacheEntry].self, forKey: .entries)
        indexedIDs = try values.decode(Set<String>.self, forKey: .indexedIDs)
        dirtyIDs = try values.decode(Set<String>.self, forKey: .dirtyIDs)
        pendingGhostDeletions = try values.decode(Set<String>.self, forKey: .pendingGhostDeletions)
        codexTitles = try values.decode([String: String].self, forKey: .codexTitles)
        iconSources = try values.decode([String: String].self, forKey: .iconSources)
        searchLaterPromptsEnabled = try values.decode(Bool.self, forKey: .searchLaterPromptsEnabled)
        laterPromptPendingPaths = try values.decode(Set<String>.self, forKey: .laterPromptPendingPaths)
        touchedFileExtractionGeneration = try values.decodeIfPresent(
            Int.self, forKey: .touchedFileExtractionGeneration) ?? 0
        touchedFilePendingPaths = try values.decodeIfPresent(
            Set<String>.self, forKey: .touchedFilePendingPaths) ?? []
    }
}
