import AppKit
import Foundation
import Observation

/// 菜单栏 / 设置 / 首次运行界面共享的可观察状态。
@MainActor
@Observable
final class UIState {
    var codexCount = 0
    var claudeCount = 0
    var parseFailures = 0
    var lastIndexed: Date?
    var lastError: String?
    var isScanning = false
    var recent: [TitledSession] = []
}

enum SpotionError: LocalizedError {
    case sessionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id): "会话已不存在：\(id)"
        }
    }
}

/// 组装 store / indexer / watcher；App Intents 与 UI 的统一入口。
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    let store: SessionStore
    let indexer = SpotlightIndexer()
    let uiState = UIState()

    private var readyTask: Task<Void, Never>?
    private var didStartBackgroundWork = false
    private var watcher: FileWatcher?
    private var reconcileTimer: Timer?
    private var firstRunController: FirstRunWindowController?
    /// 索引写操作（增量 refresh / 全量 reindex）的串行管道：
    /// watcher、系统 reindex 委托、UI 按钮可能并发触发，donate 互相踩踏会留下中间态 indexedIDs。
    private var pipeline: Task<Void, Never>?

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotion", isDirectory: true)
        store = SessionStore(
            cacheURL: appSupport.appendingPathComponent("scan-cache-v1.json"),
            codexScanner: CodexScanner(),
            claudeScanner: ClaudeScanner()
        )
    }

    /// 幂等：缓存加载完成即可服务实体查询（intent 进程可能先于 UI 到达）。
    func ensureReady() async {
        if readyTask == nil {
            readyTask = Task { await store.bootstrap() }
        }
        await readyTask?.value
    }

    /// app 启动入口
    func start() {
        Task {
            let isFirstRun = await !store.hasCacheOnDisk
            await ensureReady()
            if isFirstRun { showFirstRun() }
            startBackgroundWork()
        }
    }

    private func startBackgroundWork() {
        guard !didStartBackgroundWork else { return }
        didStartBackgroundWork = true

        Task { await indexer.installDelegate(SpotionIndexDelegate()) }
        startWatcher()
        // 每小时兜底对账（索引漂移保险）
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await AppCoordinator.shared.refreshAndApply() }
        }
        Task {
            // 需要全量重建（deleteAll + 重灌）的三种情况：
            // 1. donate 路径从 indexAppEntities 迁移到 CSSearchableItem+associateAppEntity
            // 2. 缓存 schema 升版/损坏导致旧 indexedIDs 丢失——不 deleteAll 的话，
            //    升级前已删除会话的 Spotlight 条目将永远无法清除
            // 3. 上次重建的 deleteAll 未确认成功（义务持久化在 UserDefaults，跨启动重试）
            let defaults = UserDefaults.standard
            var needsRebuild = defaults.bool(forKey: "needsFullRebuild")
            if defaults.integer(forKey: "donationPathVersion") < 2 { needsRebuild = true }
            if await store.consumePendingFullRebuild() { needsRebuild = true }

            if needsRebuild {
                // 提前持久化义务：store 的一次性重置标记已被消费，
                // 若在入队执行前崩溃，不提前落盘就会丢失重试；
                // 队内的 set→尝试→clear 生命周期由 fullReindex 保证
                defaults.set(true, forKey: "needsFullRebuild")
                await fullReindex()
            } else {
                await refreshAndApply()
            }
        }
    }

    private func startWatcher() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        watcher = FileWatcher(paths: [
            home.appendingPathComponent(".codex/sessions").path,
            home.appendingPathComponent(".codex/session_index.jsonl").path,
            home.appendingPathComponent(".claude/projects").path,
        ]) {
            Task { @MainActor in await AppCoordinator.shared.refreshAndApply() }
        }
        watcher?.start()
    }

    // MARK: - 扫描 → donate（全部经串行管道）

    func refreshAndApply() async {
        await enqueue { await self.performRefreshAndApply() }
    }

    /// 全量重建自带跨启动重试：把义务持久化到 UserDefaults，
    /// 只有 deleteAll 确认成功才清除并推进 donationPathVersion——
    /// 无论调用方是启动迁移、系统 reindex 委托、intent 还是 UI 按钮，
    /// 失败/崩溃都会在后续启动重试，而不是 ack 之后被遗忘。
    /// 标记的 set→尝试→clear 全生命周期都在串行管道【内部】完成：
    /// 并发触发排队执行时，后一次失败不会被前一次成功的 continuation 误清标记。
    /// 失败的当轮保留 indexedIDs（删除跟踪不丢），降级为普通刷新。
    @discardableResult
    func fullReindex() async -> Bool {
        await enqueue {
            UserDefaults.standard.set(true, forKey: "needsFullRebuild")
            var cleaned = false
            do {
                try await self.indexer.deleteAll()
                await self.store.forgetIndexed()
                cleaned = true
            } catch {
                NSLog("Spotion: deleteAll failed: %@", error.localizedDescription)
                self.uiState.lastError = error.localizedDescription
            }
            await self.performRefreshAndApply()
            if cleaned {
                UserDefaults.standard.set(false, forKey: "needsFullRebuild")
                UserDefaults.standard.set(2, forKey: "donationPathVersion")
            }
            return cleaned
        }
    }

    private func enqueue<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = pipeline
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        pipeline = Task { _ = await task.value }
        return await task.value
    }

    private func performRefreshAndApply() async {
        await ensureReady()
        uiState.isScanning = true
        defer { uiState.isScanning = false }
        let started = Date()

        let diff = await store.refresh(enabledAgents: SpotionSettings.enabledAgents)
        do {
            if !diff.upserts.isEmpty {
                let titled = await store.titled(records: diff.upserts)
                try await indexer.upsert(titled.map(SessionEntity.init))
            }
            if !diff.deletedIDs.isEmpty {
                try await indexer.delete(ids: diff.deletedIDs)
            }
            await store.markIndexed(diff)
            uiState.lastError = nil
        } catch {
            uiState.lastError = error.localizedDescription
            NSLog("Spotion: index apply failed: %@", error.localizedDescription)
        }

        let stats = await store.lastStats
        uiState.codexCount = stats.codexCount
        uiState.claudeCount = stats.claudeCount
        uiState.parseFailures = stats.parseFailures
        uiState.lastIndexed = Date()
        uiState.recent = await store.allTitled(limit: 5)
        if !diff.isEmpty {
            NSLog(
                "Spotion refresh: codex=%d claude=%d failures=%d upserts=%d deletes=%d in %.1fs",
                stats.codexCount, stats.claudeCount, stats.parseFailures,
                diff.upserts.count, diff.deletedIDs.count, Date().timeIntervalSince(started)
            )
        }
    }

    /// 系统点名重灌指定 id：已知的强制入 dirty 后刷新；本地已不存在的直接从索引删除。
    /// 普通增量刷新对未变更文件不会产生 upsert，直接 ack 会让这些条目永远缺失。
    func reindexIdentifiers(_ identifiers: [String]) async {
        await enqueue {
            await self.ensureReady()
            let unknown = await self.store.markDirty(ids: identifiers)
            if !unknown.isEmpty {
                do {
                    try await self.indexer.delete(ids: unknown)
                } catch {
                    NSLog("Spotion: delete of unknown reindex ids failed: %@", error.localizedDescription)
                }
            }
            await self.performRefreshAndApply()
        }
    }

    /// 某个 agent 被禁用时按域清除其结果（refresh 的删除 diff 也会兜底）。
    func agentToggled() async {
        for agent in AgentKind.allCases where !SpotionSettings.enabledAgents.contains(agent) {
            try? await indexer.deleteDomain("spotion.\(agent.rawValue)")
        }
        await refreshAndApply()
    }

    // MARK: - 打开会话

    func openSession(id: String) async throws {
        await ensureReady()
        guard let record = await store.record(id: id) else {
            throw SpotionError.sessionNotFound(id)
        }
        try await TerminalLauncher.shared.resume(record)
    }

    // MARK: - 实体查询支持（AppIntents）

    func entities(for identifiers: [String]) async -> [SessionEntity] {
        await ensureReady()
        var out: [SessionEntity] = []
        for id in identifiers {
            if let record = await store.record(id: id),
               let titled = await store.titled(records: [record]).first {
                out.append(SessionEntity(titled))
            }
        }
        return out
    }

    func recentEntities(limit: Int) async -> [SessionEntity] {
        await ensureReady()
        return await store.allTitled(limit: limit).map(SessionEntity.init)
    }

    func matchingEntities(_ query: String, limit: Int) async -> [SessionEntity] {
        await ensureReady()
        return await store.allTitled(limit: limit, matching: query).map(SessionEntity.init)
    }

    func recentProjects(limit: Int) async -> [ProjectEntity] {
        await ensureReady()
        return await store.distinctProjects().prefix(limit)
            .map { ProjectEntity(id: $0.cwd, name: $0.name) }
    }

    func matchingProjects(_ query: String, limit: Int) async -> [ProjectEntity] {
        await ensureReady()
        let needle = query.lowercased()
        return await store.distinctProjects()
            .filter { $0.name.lowercased().contains(needle) || $0.cwd.lowercased().contains(needle) }
            .prefix(limit)
            .map { ProjectEntity(id: $0.cwd, name: $0.name) }
    }

    func selfCheck(term: String) async -> Int {
        await indexer.selfCheck(term: term)
    }

    // MARK: - 首次运行

    private func showFirstRun() {
        let controller = FirstRunWindowController()
        firstRunController = controller
        controller.show()
    }
}
