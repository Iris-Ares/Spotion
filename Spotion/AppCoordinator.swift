import AppKit
import Foundation
import Observation

/// Observable state shared by the menu bar / settings / first-run UI.
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

/// Wires up store / indexer / watcher; the single entry point for App Intents
/// and the UI.
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
    /// Serial pipeline for index writes (incremental refresh / full reindex):
    /// the watcher, the system reindex delegate, and UI buttons can fire
    /// concurrently, and overlapping donations would leave indexedIDs in a
    /// partially-updated state.
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

    /// Idempotent: entity queries can be served as soon as the cache is loaded
    /// (an intent invocation may arrive before the UI does).
    func ensureReady() async {
        if readyTask == nil {
            readyTask = Task { await store.bootstrap() }
        }
        await readyTask?.value
    }

    /// App launch entry point.
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
        // Hourly reconcile as a safety net against index drift.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await AppCoordinator.shared.refreshAndApply() }
        }
        Task {
            // Three situations require a full rebuild (deleteAll + re-donate):
            // 1. The donation path migrated from indexAppEntities to
            //    CSSearchableItem+associateAppEntity.
            // 2. A cache schema bump / corruption lost the old indexedIDs —
            //    without a deleteAll, Spotlight items for sessions deleted
            //    before the upgrade could never be removed.
            // 3. A previous rebuild's deleteAll was never confirmed (the
            //    obligation is persisted in UserDefaults and retried across
            //    launches).
            let defaults = UserDefaults.standard
            var needsRebuild = defaults.bool(forKey: "needsFullRebuild")
            if defaults.integer(forKey: "donationPathVersion") < 2 { needsRebuild = true }
            if await store.consumePendingFullRebuild() { needsRebuild = true }

            if needsRebuild {
                // Persist the obligation up front: the store's one-shot reset
                // flag has already been consumed, so a crash before the queued
                // run would otherwise lose the retry. The in-queue
                // set→attempt→clear lifecycle is handled by fullReindex.
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

    // MARK: - Scan → donate (everything goes through the serial pipeline)

    func refreshAndApply() async {
        await enqueue { await self.performRefreshAndApply() }
    }

    /// Full rebuild with durable cross-launch retry: the obligation is
    /// persisted in UserDefaults and cleared — advancing donationPathVersion —
    /// only after deleteAll is confirmed. Whether the caller is the startup
    /// migration, the system reindex delegate, an intent, or the UI button, a
    /// failure or crash retries on subsequent launches instead of being
    /// forgotten after the acknowledgement.
    /// The marker's whole set→attempt→clear lifecycle runs INSIDE the serial
    /// pipeline: with overlapping triggers queued up, a later failed rebuild
    /// cannot have its obligation wiped by an earlier success's continuation.
    /// On failure the cycle keeps indexedIDs (deletion tracking intact) and
    /// degrades to a plain refresh.
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
            // The rebuild succeeded only if the wipe AND the re-donation both
            // landed — after a successful deleteAll with a failed apply, the
            // index is empty-ish, so clearing the obligation (or reporting
            // success) would be a lie. Keeping the marker set retries the
            // whole rebuild next launch.
            let applied = await self.performRefreshAndApply()
            let success = cleaned && applied
            if success {
                UserDefaults.standard.set(false, forKey: "needsFullRebuild")
                UserDefaults.standard.set(2, forKey: "donationPathVersion")
            }
            return success
        }
    }

    /// Compensation for a timed-out wipe (deleteAll/deleteDomain) whose XPC
    /// completion later fired anyway: the zombie erased items indexedIDs still
    /// claims exist, so forget the indexed set and re-donate everything.
    func recoverFromLateWipe() async {
        await enqueue {
            await self.store.forgetIndexed()
            await self.performRefreshAndApply()
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

    /// Returns whether the donate/delete apply completed without error (the
    /// scan itself is infallible; a false return means the diff was left for
    /// the dirty/indexed retry mechanics).
    @discardableResult
    private func performRefreshAndApply() async -> Bool {
        await ensureReady()
        uiState.isScanning = true
        defer { uiState.isScanning = false }
        let started = Date()
        var applied = true

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
            applied = false
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
        return applied
    }

    /// The system asked to reindex specific ids: known ones are forced dirty
    /// and refreshed; ones that no longer exist locally are deleted from the
    /// index directly. A plain incremental refresh would produce no upserts
    /// for unchanged files, and acknowledging after it would leave those
    /// items missing forever.
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

    /// Clears a disabled agent's results by domain (the refresh deletion diff
    /// also covers this as a fallback). The whole operation runs inside the
    /// serial pipeline — with a detached deleteDomain, a quick disable→enable
    /// could let the re-enable refresh run first (ids still marked indexed, no
    /// upserts) and the late domain deletion would then remove those items
    /// from Spotlight until a rebuild. Enabled-ness is also re-read inside the
    /// queued work, so a toggle reverted before its turn becomes a no-op.
    func agentToggled() async {
        await enqueue {
            for agent in AgentKind.allCases where !SpotionSettings.enabledAgents.contains(agent) {
                try? await self.indexer.deleteDomain("spotion.\(agent.rawValue)")
            }
            await self.performRefreshAndApply()
        }
    }

    // MARK: - Opening sessions

    func openSession(id: String) async throws {
        await ensureReady()
        guard let record = await store.record(id: id) else {
            throw SpotionError.sessionNotFound(id)
        }
        try await TerminalLauncher.shared.resume(record)
    }

    // MARK: - Entity query support (AppIntents)

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

    // MARK: - First run

    private func showFirstRun() {
        let controller = FirstRunWindowController()
        firstRunController = controller
        controller.show()
    }
}
