import Foundation

struct SessionDiff: Sendable {
    var upserts: [SessionRecord] = []
    var deletedIDs: [String] = []
    var isEmpty: Bool { upserts.isEmpty && deletedIDs.isEmpty }
}

struct StoreStats: Sendable {
    var codexCount = 0
    var claudeCount = 0
    var parseFailures = 0
    var lastRefresh: Date?
}

struct ProjectInfo: Sendable, Hashable {
    var cwd: String
    var name: String
    var lastUsed: Date
}

/// Record plus its resolved display title (codex titles live in the store's
/// codexTitles map, so they must be resolved before crossing the actor boundary).
struct TitledSession: Sendable, Hashable {
    var record: SessionRecord
    var title: String
}

/// Single owner of all session state: mtime+size incremental scanning,
/// title resolution, and diffing against the set of already-donated ids.
actor SessionStore {
    private let cacheURL: URL
    private let codexScanner: CodexScanner?
    private let claudeScanner: ClaudeScanner?
    private var projectExclusions: ProjectExclusionStore

    private var cache = ScanCache()
    /// id → record, rebuilt from cache.entries
    private var records: [String: SessionRecord] = [:]
    private(set) var lastStats = StoreStats()
    /// A cache file exists on disk but is unusable (version mismatch / decode
    /// failure): the old indexedIDs are gone, so sessions deleted before the
    /// upgrade can never produce deletedIDs — a deleteAll + full re-donation
    /// is required.
    private var pendingFullRebuild = false

    init(
        cacheURL: URL,
        projectExclusionsURL: URL? = nil,
        codexScanner: CodexScanner?,
        claudeScanner: ClaudeScanner?
    ) {
        self.cacheURL = cacheURL
        self.codexScanner = codexScanner
        self.claudeScanner = claudeScanner
        projectExclusions = ProjectExclusionStore(
            url: projectExclusionsURL
                ?? cacheURL.deletingLastPathComponent().appendingPathComponent("project-exclusions-v1.json"))
    }

    // MARK: - Lifecycle

    func bootstrap() {
        projectExclusions.load()
        let fileExists = FileManager.default.fileExists(atPath: cacheURL.path)
        guard let data = try? Data(contentsOf: cacheURL),
              let loaded = try? JSONDecoder().decode(ScanCache.self, from: data),
              loaded.version == ScanCache.currentVersion else {
            cache = ScanCache()
            pendingFullRebuild = fileExists
            return
        }
        cache = loaded
        rebuildRecords()
    }

    /// Read and clear the full-rebuild flag (consumed once by the coordinator
    /// after bootstrap).
    func consumePendingFullRebuild() -> Bool {
        defer { pendingFullRebuild = false }
        return pendingFullRebuild
    }

    /// Rebuild id → record from entries. `codex resume`/`fork` create multiple
    /// rollout files for the same session_id — on collision keep the file with
    /// the newest lastActivityAt (reflects recent activity correctly, and
    /// automatically falls back to the older file when the newest is deleted).
    private func rebuildRecords() {
        records = [:]
        for entry in cache.entries.values {
            guard let record = entry.record else { continue }
            if let existing = records[record.id], existing.lastActivityAt >= record.lastActivityAt {
                continue
            }
            records[record.id] = record
        }
    }

    var hasCacheOnDisk: Bool {
        FileManager.default.fileExists(atPath: cacheURL.path)
    }

    // MARK: - Incremental refresh

    /// iconSources: per-agent opaque fingerprint of the artwork donated with
    /// that agent's items (the coordinator derives it from the resolved handler
    /// app). A fingerprint differing from the cached one marks every session
    /// of the agent dirty, so unchanged sessions re-donate their thumbnail
    /// after the handler app is installed, removed, or replaced. Agents absent
    /// from the map are not checked.
    func refresh(
        enabledAgents: Set<AgentKind>,
        iconSources: [AgentKind: String] = [:],
        includeLaterPrompts: Bool = false
    ) async -> SessionDiff {
        var changedIDs = Set<String>()
        var seenPaths = Set<String>()
        var hydratedPromptPaths = Set<String>()

        if cache.searchLaterPromptsEnabled != includeLaterPrompts {
            cache.searchLaterPromptsEnabled = includeLaterPrompts
            if includeLaterPrompts {
                // Queue every unchanged cached transcript for one bounded tail
                // reparse; successful parses remove their own path below.
                cache.laterPromptPendingPaths = Set(cache.entries.keys)
            } else {
                // Privacy fail-safe: purge cached snippets immediately. The
                // entity layer also ignores them while disabled. Mark every
                // record changed even when a relaunch already discarded its
                // transient snippets, so Spotlight overwrites previously
                // donated private text.
                cache.laterPromptPendingPaths = []
                for path in Array(cache.entries.keys) {
                    guard var record = cache.entries[path]?.record else { continue }
                    record.laterPromptSnippets = []
                    cache.entries[path]?.record = record
                    changedIDs.insert(record.id)
                }
            }
        }

        // Resolve metadata-only re-donation triggers before file enumeration,
        // so opt-in prompt snippets (which are deliberately not persisted in
        // the scan cache) can be rehydrated in the same refresh.
        if enabledAgents.contains(.codex), let codexScanner,
           let newTitles = codexScanner.loadTitleIndex() {
            var affected = Set<String>()
            for (sessionID, name) in newTitles where cache.codexTitles[sessionID] != name {
                affected.insert(sessionID)
            }
            for sessionID in cache.codexTitles.keys where newTitles[sessionID] == nil {
                affected.insert(sessionID)
            }
            for sessionID in affected {
                let id = SessionRecord.makeID(agent: .codex, sessionID: sessionID)
                if records[id] != nil { changedIDs.insert(id) }
            }
            cache.codexTitles = newTitles
        }

        for (agent, fingerprint) in iconSources
        where cache.iconSources[agent.rawValue] != fingerprint {
            cache.iconSources[agent.rawValue] = fingerprint
            for record in records.values where record.agent == agent {
                changedIDs.insert(record.id)
            }
        }

        if includeLaterPrompts {
            let needsHydration = cache.dirtyIDs
                .union(changedIDs)
                .union(Set(records.keys).subtracting(cache.indexedIDs))
            for (path, entry) in cache.entries {
                if let id = entry.record?.id, needsHydration.contains(id) {
                    cache.laterPromptPendingPaths.insert(path)
                }
            }
        }

        struct RootState {
            var path: String
            var trustworthy: Bool  // enumeration result is reliable (not a suspected transient failure)
            var enabled: Bool
        }
        var roots: [RootState] = []
        var toParse: [(scanner: any SessionScanner, file: ScannedFile)] = []

        let scanners: [any SessionScanner] = [codexScanner as (any SessionScanner)?, claudeScanner]
            .compactMap { $0 }

        for scanner in scanners {
            // canonicalPath (realpath semantics): FileManager enumeration returns
            // symlink-resolved canonical paths (e.g. /var → /private/var), so the
            // root must be canonicalized the same way for prefix matching to hold.
            // Do NOT use resolvingSymlinksInPath() — it strips the /private prefix
            // in the opposite direction.
            let rootPath = (try? URL(fileURLWithPath: scanner.rootPath)
                .resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? scanner.rootPath
            guard enabledAgents.contains(scanner.agent) else {
                roots.append(RootState(path: rootPath, trustworthy: true, enabled: false))
                continue
            }
            // nil = enumeration failed (permission blip etc.) → no deletions for
            // this root this cycle; [] = genuinely empty root, deletions proceed.
            guard let files = scanner.enumerateFiles() else {
                roots.append(RootState(path: rootPath, trustworthy: false, enabled: true))
                continue
            }
            roots.append(RootState(path: rootPath, trustworthy: true, enabled: true))

            for file in files {
                seenPaths.insert(file.path)
                if let entry = cache.entries[file.path],
                   entry.mtime == file.mtime, entry.size == file.size,
                   !cache.laterPromptPendingPaths.contains(file.path) {
                    continue
                }
                toParse.append((scanner, file))
            }
        }

        // Parse changed files in parallel (pure value functions, I/O bound)
        let parsed = await withTaskGroup(of: (ScannedFile, ParseOutcome).self) { group in
            for (scanner, file) in toParse {
                group.addTask { (file, scanner.parse(file, includeLaterPrompts: includeLaterPrompts)) }
            }
            var results: [(ScannedFile, ParseOutcome)] = []
            for await item in group { results.append(item) }
            return results
        }
        for (file, outcome) in parsed {
            // I/O failure: do NOT touch the cache entry. The kept entry's stale
            // mtime/size guarantee a re-parse attempt on the next refresh once
            // the file is readable again — caching nil here would evict the
            // session and never retry (the new mtime would match forever).
            if case .ioFailure = outcome { continue }
            cache.laterPromptPendingPaths.remove(file.path)
            if includeLaterPrompts { hydratedPromptPaths.insert(file.path) }
            var record = outcome.record
            // Claude desktop's claude://resume import rewrites the transcript
            // in place with the tail title records stripped. Same path + same
            // session id but the title vanished → carry the previous title
            // forward instead of degrading the Spotlight row to its first
            // prompt. A later legitimate title record overwrites it normally.
            if var updated = record, updated.fallbackTitle == nil,
               let previous = cache.entries[file.path]?.record,
               previous.id == updated.id, previous.fallbackTitle != nil {
                updated.fallbackTitle = previous.fallbackTitle
                record = updated
            }
            // If this path previously held a valid record and now parses to nil
            // (or to a different id), the old id must be marked changed: a
            // fallback rollout with the same id needs re-donation, and a fully
            // vanished session flows into deletedIDs. Without this, the id
            // stays in indexedIDs and Spotlight keeps the dead file's metadata.
            if let previous = cache.entries[file.path]?.record, previous.id != record?.id {
                changedIDs.insert(previous.id)
            }
            cache.entries[file.path] = ScanCacheEntry(mtime: file.mtime, size: file.size, record: record)
            if let record { changedIDs.insert(record.id) }
        }

        // Deletions: a cached entry's file vanished (or its agent was disabled).
        // The prefix carries a "/" boundary so …/sessions cannot accidentally
        // match a sibling like …/sessionsXYZ.
        for path in cache.entries.keys where !seenPaths.contains(path) {
            if let root = roots.first(where: { path.hasPrefix($0.path + "/") }),
               root.enabled, !root.trustworthy {
                continue  // suspected transient failure — keep the entry
            }
            if let removed = cache.entries.removeValue(forKey: path)?.record {
                // The removed file may be the winning file of a duplicated
                // session_id: mark the id changed so the fallback file (if any)
                // is re-donated with corrected metadata; if the session is fully
                // gone it flows into deletedIDs instead.
                changedIDs.insert(removed.id)
            }
            cache.laterPromptPendingPaths.remove(path)
        }

        // Rebuild uniformly from entries (handles winner selection among
        // multiple files sharing a session_id, and deletion fallback).
        rebuildRecords()

        // A deleted/corrupted winning rollout may reveal an unchanged fallback
        // record that was decoded without private prompt text. Defer that
        // upsert one cycle and queue its winning path for bounded hydration.
        if includeLaterPrompts {
            for id in changedIDs {
                guard let record = records[id],
                      !hydratedPromptPaths.contains(record.filePath) else { continue }
                cache.laterPromptPendingPaths.insert(record.filePath)
            }
        }

        let currentIDs = Set(records.keys)
        let visibleCurrentIDs: Set<String> = if projectExclusions.isAvailable {
            Set(currentIDs.filter { id in
                guard let record = records[id] else { return false }
                return !projectExclusions.excludes(cwd: record.cwd)
            })
        } else {
            []
        }
        // Changed ids enter the dirty set and stay until markIndexed (donation
        // confirmed) clears them — failures therefore retry automatically.
        cache.dirtyIDs.formUnion(changedIDs)
        cache.dirtyIDs.formIntersection(visibleCurrentIDs)
        let upsertIDs = cache.dirtyIDs.union(visibleCurrentIDs.subtracting(cache.indexedIDs))
        let promptHydrationBlockedIDs = includeLaterPrompts ? Set(upsertIDs.filter {
            guard let path = records[$0]?.filePath else { return false }
            return cache.laterPromptPendingPaths.contains(path)
        }) : []
        let diff = SessionDiff(
            upserts: upsertIDs.subtracting(promptHydrationBlockedIDs).compactMap { records[$0] },
            deletedIDs: Array(cache.indexedIDs.subtracting(visibleCurrentIDs))
        )

        lastStats = StoreStats(
            codexCount: visibleCurrentIDs.compactMap { records[$0] }.count(where: { $0.agent == .codex }),
            claudeCount: visibleCurrentIDs.compactMap { records[$0] }.count(where: { $0.agent == .claude }),
            parseFailures: cache.entries.values.count(where: { $0.record == nil }),
            lastRefresh: Date()
        )
        persist()
        return diff
    }

    /// Called when the system (Core Spotlight delegate) requests specific ids:
    /// known ids are forced into the dirty set so the next refresh must upsert
    /// them; returns the ids that no longer exist locally (the caller should
    /// delete those from the index directly).
    func markDirty(ids: [String]) -> [String] {
        var unknown: [String] = []
        for id in ids {
            if let record = records[id], !projectExclusions.excludes(cwd: record.cwd) {
                cache.dirtyIDs.insert(id)
            } else {
                // A system reindex request for an excluded id is evidence that
                // Spotlight still has (or resurrected) it. Route it through
                // the durable ghost-deletion queue instead of re-donating it.
                unknown.append(id)
            }
        }
        persist()
        return unknown
    }

    // MARK: - Ghost deletions (items tracked by neither records nor indexedIDs)

    /// Queue Spotlight items for deletion that have no local record and are
    /// absent from indexedIDs — without persistence they would have no retry
    /// path once the direct deletion fails.
    func addPendingGhostDeletions(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        cache.pendingGhostDeletions.formUnion(ids)
        persist()
    }

    func pendingGhostDeletions() -> [String] {
        Array(cache.pendingGhostDeletions)
    }

    /// Called after the ghost deletion actually landed.
    func clearGhostDeletions(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        cache.pendingGhostDeletions.subtract(ids)
        persist()
    }

    /// Called after a successful donation: update the indexed set, clear the
    /// corresponding dirty flags, and persist.
    func markIndexed(_ diff: SessionDiff) {
        let upsertedIDs = diff.upserts.map(\.id)
        cache.indexedIDs.formUnion(upsertedIDs)
        cache.indexedIDs.subtract(diff.deletedIDs)
        cache.dirtyIDs.subtract(upsertedIDs)
        persist()
    }

    /// Called before a full reindex: clear the indexed set so the next refresh
    /// reports every session as an upsert.
    func forgetIndexed() {
        cache.indexedIDs = []
        persist()
    }

    // MARK: - Queries

    func record(id: String) -> SessionRecord? {
        guard let record = records[id], !projectExclusions.excludes(cwd: record.cwd) else {
            return nil
        }
        return record
    }

    func all(limit: Int? = nil, matching query: String? = nil) -> [SessionRecord] {
        var result = records.values.filter { !projectExclusions.excludes(cwd: $0.cwd) }
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let needle = query.lowercased()
            result = result.filter {
                displayTitle(for: $0).lowercased().contains(needle)
                    || $0.projectName.lowercased().contains(needle)
                    || $0.cwd.lowercased().contains(needle)
            }
        }
        result.sort { $0.lastActivityAt > $1.lastActivityAt }
        if let limit { result = Array(result.prefix(limit)) }
        return result
    }

    func distinctProjects() -> [ProjectInfo] {
        var byCwd: [String: Date] = [:]
        for record in records.values where !projectExclusions.excludes(cwd: record.cwd) {
            byCwd[record.cwd] = max(byCwd[record.cwd] ?? .distantPast, record.lastActivityAt)
        }
        return byCwd
            .map { ProjectInfo(cwd: $0.key, name: ($0.key as NSString).lastPathComponent, lastUsed: $0.value) }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    /// codex: session_index title > first prompt > project name;
    /// claude: tail title records > first prompt > project name.
    func displayTitle(for record: SessionRecord) -> String {
        let raw: String? = switch record.agent {
        case .codex: cache.codexTitles[record.sessionID] ?? record.firstPrompt
        case .claude: record.fallbackTitle ?? record.firstPrompt
        }
        let sanitized = raw?.titleSanitized ?? ""
        return sanitized.isEmpty ? record.projectName : sanitized
    }

    func titled(records: [SessionRecord]) -> [TitledSession] {
        records.map { TitledSession(record: $0, title: displayTitle(for: $0)) }
    }

    func allTitled(limit: Int? = nil, matching query: String? = nil) -> [TitledSession] {
        titled(records: all(limit: limit, matching: query))
    }

    // MARK: - Project exclusions

    func addProjectExclusion(path: String) throws -> Bool {
        let previouslyVisible = Set(records.values.filter {
            !projectExclusions.excludes(cwd: $0.cwd)
        }.map(\.id))
        guard try projectExclusions.add(path: path) != nil else { return false }

        let newlyExcluded = previouslyVisible.filter { id in
            guard let record = records[id] else { return false }
            return projectExclusions.excludes(cwd: record.cwd)
        }
        cache.dirtyIDs.subtract(newlyExcluded)
        persist()
        return true
    }

    func removeProjectExclusion(path: String) throws -> Bool {
        let previouslyExcluded = Set(records.values.filter {
            projectExclusions.excludes(cwd: $0.cwd)
        }.map(\.id))
        guard try projectExclusions.remove(path: path) != nil else { return false }

        let newlyVisible = previouslyExcluded.filter { id in
            guard let record = records[id] else { return false }
            return !projectExclusions.excludes(cwd: record.cwd)
        }
        cache.dirtyIDs.formUnion(newlyVisible)
        persist()
        return true
    }

    func projectExclusionList() -> [ProjectExclusion] {
        projectExclusions.exclusions()
    }

    var exclusionStateMessage: String? {
        projectExclusions.statusMessage
    }

    func scanReport() -> String {
        var lines = [
            "Spotion scan report",
            "codex=\(lastStats.codexCount) claude=\(lastStats.claudeCount) parseFailures=\(lastStats.parseFailures)",
            "indexedIDs=\(cache.indexedIDs.count) lastRefresh=\(lastStats.lastRefresh.map(String.init(describing:)) ?? "never")",
            "",
        ]
        for record in all(limit: 5) {
            lines.append("[\(record.agent.rawValue)] \(displayTitle(for: record)) — \(record.projectName) — \(record.lastActivityAt)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("Spotion: cache persist failed: %@", error.localizedDescription)
        }
    }
}
