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

/// record + 解析好的显示标题（codex 标题在 store 的 codexTitles 里，跨界传递时需一并解析）
struct TitledSession: Sendable, Hashable {
    var record: SessionRecord
    var title: String
}

/// 全部会话状态的唯一持有者：mtime+size 增量扫描、标题解析、与已 donate 集合的 diff。
actor SessionStore {
    private let cacheURL: URL
    private let codexScanner: CodexScanner?
    private let claudeScanner: ClaudeScanner?

    private var cache = ScanCache()
    /// id → record，从 cache.entries 重建
    private var records: [String: SessionRecord] = [:]
    private(set) var lastStats = StoreStats()
    /// 磁盘上存在缓存文件但不可用（版本不匹配 / 解码失败）：旧 indexedIDs 已丢失，
    /// 升级前删除的会话无从产生 deletedIDs——必须走一次 deleteAll + 全量重灌
    private var pendingFullRebuild = false

    init(cacheURL: URL, codexScanner: CodexScanner?, claudeScanner: ClaudeScanner?) {
        self.cacheURL = cacheURL
        self.codexScanner = codexScanner
        self.claudeScanner = claudeScanner
    }

    // MARK: - 生命周期

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

    /// 读取并清除全量重建标记（bootstrap 后由 coordinator 消费一次）
    func consumePendingFullRebuild() -> Bool {
        defer { pendingFullRebuild = false }
        return pendingFullRebuild
    }

    /// 从 entries 重建 id→record。codex resume/fork 会为同一 session_id 生成多个
    /// rollout 文件——同 id 碰撞时保留 lastActivityAt 最新的文件（正确反映最近活动，
    /// 且最新文件被删除时自动回退到旧文件）。
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

    // MARK: - 增量刷新

    func refresh(enabledAgents: Set<AgentKind>) async -> SessionDiff {
        var changedIDs = Set<String>()
        var seenPaths = Set<String>()

        struct RootState {
            var path: String
            var trustworthy: Bool  // 枚举结果可信（非疑似瞬时失败）
            var enabled: Bool
        }
        var roots: [RootState] = []
        var toParse: [(scanner: any SessionScanner, file: ScannedFile)] = []

        let scanners: [any SessionScanner] = [codexScanner as (any SessionScanner)?, claudeScanner]
            .compactMap { $0 }

        for scanner in scanners {
            // canonicalPath（realpath 语义）：FileManager 枚举返回的是符号链接解析后的
            // 规范路径（如 /var → /private/var），根路径必须同样规范化，前缀匹配才成立。
            // 注意不能用 resolvingSymlinksInPath()——它会反向剥掉 /private 前缀。
            let rootPath = (try? URL(fileURLWithPath: scanner.rootPath)
                .resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? scanner.rootPath
            guard enabledAgents.contains(scanner.agent) else {
                roots.append(RootState(path: rootPath, trustworthy: true, enabled: false))
                continue
            }
            // nil = 枚举失败（权限抖动等）→ 本轮不对该根做删除；[] = 真空目录，删除照常
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

        // 变更文件并行解析（纯值函数，IO 密集）
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

        // 删除处理：缓存条目的文件已消失（或所属 agent 被禁用）。
        // 前缀带 "/" 边界，避免 …/sessions 误匹配 …/sessionsXYZ 兄弟目录。
        for path in cache.entries.keys where !seenPaths.contains(path) {
            if let root = roots.first(where: { path.hasPrefix($0.path + "/") }),
               root.enabled, !root.trustworthy {
                continue  // 疑似瞬时失败，保留
            }
            if let removed = cache.entries.removeValue(forKey: path)?.record {
                // 被删的可能是同 session_id 的胜者文件：标记变更，
                // 回退文件（若存在）会重新 donate 修正元数据；完全消失则走 deletedIDs
                changedIDs.insert(removed.id)
            }
        }

        // 统一从 entries 重建（处理同 session_id 多文件的胜者选择与删除回退）
        rebuildRecords()

        // codex 标题索引：变化只触发重新 donate，不重读 rollout 文件
        if enabledAgents.contains(.codex), let codexScanner {
            let newTitles = codexScanner.loadTitleIndex()
            for (sessionID, name) in newTitles where cache.codexTitles[sessionID] != name {
                let id = SessionRecord.makeID(agent: .codex, sessionID: sessionID)
                if records[id] != nil { changedIDs.insert(id) }
            }
            cache.codexTitles = newTitles
        }

        let currentIDs = Set(records.keys)
        // 变更 id 进入 dirty 集合，直到 markIndexed（donate 成功）才清除——失败自动重试
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

    /// donate 成功后调用，更新已索引集合、清除对应 dirty 标记并落盘
    func markIndexed(_ diff: SessionDiff) {
        let upsertedIDs = diff.upserts.map(\.id)
        cache.indexedIDs.formUnion(upsertedIDs)
        cache.indexedIDs.subtract(diff.deletedIDs)
        cache.dirtyIDs.subtract(upsertedIDs)
        persist()
    }

    /// 全量 Reindex 前调用：清空已索引集合，下轮 refresh 会把所有会话报为 upserts
    func forgetIndexed() {
        cache.indexedIDs = []
        persist()
    }

    // MARK: - 查询

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

    /// codex：session_index 标题 > 首 prompt > 项目名；claude：尾部标题记录 > 首 prompt > 项目名
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

    // MARK: - 持久化

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
