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

    private var cache = ScanCache()
    /// id → record, rebuilt from cache.entries
    private var records: [String: SessionRecord] = [:]
    private(set) var lastStats = StoreStats()
    /// A cache file exists on disk but is unusable (version mismatch / decode
    /// failure): the old indexedIDs are gone, so sessions deleted before the
    /// upgrade can never produce deletedIDs — a deleteAll + full re-donation
    /// is required.
    private var pendingFullRebuild = false

    init(cacheURL: URL, codexScanner: CodexScanner?, claudeScanner: ClaudeScanner?) {
        self.cacheURL = cacheURL
        self.codexScanner = codexScanner
        self.claudeScanner = claudeScanner
    }

    // MARK: - Lifecycle

    func bootstrap() {
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

    func refresh(enabledAgents: Set<AgentKind>) async -> SessionDiff {
        var changedIDs = Set<String>()
        var seenPaths = Set<String>()

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
                if let entry = cache.entries[file.path], entry.mtime == file.mtime, entry.size == file.size {
                    continue
                }
                toParse.append((scanner, file))
            }
        }

        // Parse changed files in parallel (pure value functions, I/O bound)
        let parsed = await withTaskGroup(of: (ScannedFile, SessionRecord?).self) { group in
            for (scanner, file) in toParse {
                group.addTask { (file, scanner.parse(file)) }
            }
            var results: [(ScannedFile, SessionRecord?)] = []
            for await item in group { results.append(item) }
            return results
        }
        for (file, record) in parsed {
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
        }

        // Rebuild uniformly from entries (handles winner selection among
        // multiple files sharing a session_id, and deletion fallback).
        rebuildRecords()

        // Codex title index: changes only trigger re-donation, never a rollout
        // re-read. Compare both directions — besides new/renamed entries, a
        // cleared title or a vanished entry (present before, absent now) must
        // also re-donate, or Spotlight keeps the stale title until the rollout
        // file itself changes.
        // loadTitleIndex() == nil means the read failed: keep the cached titles
        // and skip the diff this cycle, so an I/O blip is not mistaken for
        // "all titles cleared" and a mass downgrade re-donation.
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

        let currentIDs = Set(records.keys)
        // Changed ids enter the dirty set and stay until markIndexed (donation
        // confirmed) clears them — failures therefore retry automatically.
        cache.dirtyIDs.formUnion(changedIDs)
        cache.dirtyIDs.formIntersection(currentIDs)
        let diff = SessionDiff(
            upserts: cache.dirtyIDs.union(currentIDs.subtracting(cache.indexedIDs)).compactMap { records[$0] },
            deletedIDs: Array(cache.indexedIDs.subtracting(currentIDs))
        )

        lastStats = StoreStats(
            codexCount: records.values.count(where: { $0.agent == .codex }),
            claudeCount: records.values.count(where: { $0.agent == .claude }),
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
            if records[id] != nil {
                cache.dirtyIDs.insert(id)
            } else {
                unknown.append(id)
            }
        }
        persist()
        return unknown
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

    func record(id: String) -> SessionRecord? { records[id] }

    func all(limit: Int? = nil, matching query: String? = nil) -> [SessionRecord] {
        var result = Array(records.values)
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
        for record in records.values {
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
