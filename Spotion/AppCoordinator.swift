import AppIntents
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
    var pinned: [TitledSession] = []
    var recent: [TitledSession] = []
    /// Sessions eligible for Spotlight vs. everything scanned (hidden and
    /// otherwise filtered records stay in the cache but not in the index).
    var visibleCount = 0
    var totalCount = 0
    /// Non-fatal state problems (recovered sidecar files etc.), refreshed
    /// every cycle; `lastError` is reserved for the apply failure itself.
    var warnings: [String] = []
    var hiddenSessions: [HiddenSessionSnapshot] = []
    var excludedProjects: [ProjectExclusion] = []
    var availableProjects: [ProjectInfo] = []
}

/// Wires up store / indexer / watcher; the single entry point for App Intents
/// and the UI.
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    let store: SessionStore
    let indexer = SpotlightIndexer()
    private var savedProjectStore: SavedProjectStore
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
            hiddenSessionsURL: appSupport.appendingPathComponent("hidden-sessions-v1.json"),
            projectExclusionsURL: appSupport.appendingPathComponent("project-exclusions-v1.json"),
            codexScanner: CodexScanner(),
            claudeScanner: ClaudeScanner(),
            historyWindow: SpotionSettings.spotlightHistoryWindow,
            pinnedSessionsURL: appSupport.appendingPathComponent("pinned-sessions-v1.json"),
            aliasesURL: appSupport.appendingPathComponent("session-aliases-v1.json")
        )
        savedProjectStore = SavedProjectStore(
            fileURL: appSupport.appendingPathComponent("saved-quick-create-projects-v1.json"))
        savedProjectStore.load()
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
            // 1. The donated content generation advanced (v2: indexAppEntities
            //    → CSSearchableItem+associateAppEntity; v3: per-agent thumbnail
            //    attributes; v4: exact session-ID keywords) — an incremental
            //    refresh would never re-donate unchanged sessions, leaving old
            //    items in the stale format.
            // 2. A cache schema bump / corruption lost the old indexedIDs —
            //    without a deleteAll, Spotlight items for sessions deleted
            //    before the upgrade could never be removed.
            // 3. A previous rebuild's deleteAll was never confirmed (the
            //    obligation is persisted in UserDefaults and retried across
            //    launches).
            let defaults = UserDefaults.standard
            var needsRebuild = defaults.bool(forKey: "needsFullRebuild")
            if DonatedContentGeneration.requiresFullRebuild(
                stored: defaults.integer(forKey: "donationPathVersion")
            ) { needsRebuild = true }
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
                UserDefaults.standard.set(
                    DonatedContentGeneration.current,
                    forKey: "donationPathVersion"
                )
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

    /// Compensation for a timed-out item-level mutation (upsert/delete) whose
    /// XPC completion later fired anyway. The zombie may have resurrected
    /// items for sessions deleted in the meantime (an upsert landing after the
    /// cleanup) or erased items for sessions that reappeared (a delete landing
    /// after a re-donation). markDirty splits the batch: known ids re-donate
    /// fresh content on top of whatever the zombie wrote; unknown ids are
    /// ghosts and get deleted from the index.
    func reconcileLateItemMutation(ids: [String]) async {
        await enqueue {
            await self.ensureReady()
            let ghosts = await self.store.markDirty(ids: ids)
            // Ghosts resurrected by a late mutation get a durable deletion
            // queue; performRefreshAndApply retries until they land.
            await self.store.addPendingGhostDeletions(ghosts)
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

    private func enqueueThrowing<T: Sendable>(
        _ work: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = pipeline
        let task = Task { @MainActor () throws -> T in
            await previous?.value
            return try await work()
        }
        pipeline = Task { _ = try? await task.value }
        return try await task.value
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

        // Fingerprint each enabled agent's icon source so the store can force
        // a re-donation of unchanged sessions when a handler app was
        // installed, removed, or replaced since the last pass.
        let enabled = SpotionSettings.enabledAgents
        let iconSources = Dictionary(uniqueKeysWithValues: enabled.map {
            ($0, AgentIconProvider.shared.sourceFingerprint(for: $0))
        })
        let diff = await store.refresh(
            enabledAgents: enabled,
            iconSources: iconSources,
            includeLaterPrompts: SpotionSettings.searchLaterPrompts,
            historyWindow: SpotionSettings.spotlightHistoryWindow,
            now: started,
            includeTouchedFiles: SpotionSettings.searchTouchedFiles
        )
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

        // Ghost deletions (untracked Spotlight items queued by reindex requests
        // or late zombie mutations) retry every cycle until they land. Their
        // failure does not flip `applied` — they are orthogonal to the
        // wipe+donate contract and have their own durable retry.
        let ghosts = await store.pendingGhostDeletions()
        if !ghosts.isEmpty {
            do {
                try await indexer.delete(ids: ghosts)
                await store.clearGhostDeletions(ghosts)
            } catch {
                NSLog("Spotion: ghost deletion retry failed: %@", error.localizedDescription)
            }
        }

        let stats = await store.lastStats
        uiState.codexCount = stats.codexCount
        uiState.claudeCount = stats.claudeCount
        uiState.parseFailures = stats.parseFailures
        uiState.visibleCount = stats.visibleCount
        uiState.totalCount = stats.totalCount
        uiState.warnings = await store.warnings()
        uiState.lastIndexed = Date()
        let menu = await store.menuSections(recentLimit: 5)
        uiState.pinned = menu.pinned
        uiState.recent = menu.recent
        uiState.hiddenSessions = await store.hiddenSessionSnapshots()
        uiState.excludedProjects = await store.projectExclusionList()
        uiState.availableProjects = await store.distinctProjects()
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
            // Unknown ids are tracked by neither records nor indexedIDs — queue
            // them durably; performRefreshAndApply retries until they land.
            await self.store.addPendingGhostDeletions(unknown)
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

    // MARK: - Spotion-only hidden sessions

    func hideSession(id: String) async throws {
        try await enqueueThrowing {
            await self.ensureReady()
            guard try await self.store.hideSession(id: id) else { return }
            guard await self.performRefreshAndApply() else {
                throw SpotionError.indexMutationPending("隐藏状态")
            }
        }
    }

    func restoreSession(id: String) async throws {
        try await enqueueThrowing {
            await self.ensureReady()
            guard try await self.store.restoreSession(id: id) else { return }
            guard await self.performRefreshAndApply() else {
                throw SpotionError.indexMutationPending("恢复状态")
            }
        }
    }

    // MARK: - Project exclusions

    func addProjectExclusion(path: String) async throws {
        try await enqueueThrowing {
            await self.ensureReady()
            guard try await self.store.addProjectExclusion(path: path) else { return }
            guard await self.performRefreshAndApply() else {
                throw SpotionError.indexMutationPending("项目排除规则")
            }
        }
    }

    func removeProjectExclusion(path: String) async throws {
        try await enqueueThrowing {
            await self.ensureReady()
            guard try await self.store.removeProjectExclusion(path: path) else { return }
            guard await self.performRefreshAndApply() else {
                throw SpotionError.indexMutationPending("项目恢复规则")
            }
        }
    }

    // MARK: - Pins

    func pinSession(id: String) async throws {
        try await updatePin(id: id, pinned: true)
    }

    func unpinSession(id: String) async throws {
        try await updatePin(id: id, pinned: false)
    }

    private func updatePin(id: String, pinned: Bool) async throws {
        try await enqueueThrowing {
            await self.ensureReady()
            switch try await self.store.setPinned(id: id, pinned: pinned) {
            case .unknownSession:
                throw SpotionError.sessionNotFound(id)
            case .unchanged:
                return
            case .changed:
                guard await self.performRefreshAndApply() else {
                    throw SpotionError.indexMutationPending("置顶状态")
                }
            }
        }
    }

    // MARK: - Spotion-only aliases

    func setSessionAlias(id: String, alias: String) async throws {
        try await updateAlias(id: id, alias: alias)
    }

    func clearSessionAlias(id: String) async throws {
        try await updateAlias(id: id, alias: nil)
    }

    private func updateAlias(id: String, alias: String?) async throws {
        try await enqueueThrowing {
            await self.ensureReady()
            let result = if let alias {
                try await self.store.setAlias(id: id, alias: alias)
            } else {
                try await self.store.clearAlias(id: id)
            }
            switch result {
            case .unknownSession:
                throw SpotionError.sessionNotFound(id)
            case .unchanged:
                return
            case .changed:
                guard await self.performRefreshAndApply() else {
                    throw SpotionError.indexMutationPending("别名")
                }
            }
        }
    }

    // MARK: - Opening sessions

    @discardableResult
    func openSession(id: String) async throws -> LaunchDestination {
        await ensureReady()
        guard let record = await store.record(id: id) else {
            throw SpotionError.sessionNotFound(id)
        }
        switch SpotionSettings.launchTarget(for: record.agent) {
        case .cli:
            try await TerminalLauncher.shared.resume(record)
            return .terminal(SpotionSettings.terminal)
        case .nativeApp:
            return .nativeApp(appName: try await NativeAppLauncher.shared.resume(record))
        }
    }

    /// Select from one consistent store snapshot, then re-enter the existing
    /// exact-ID open path. If the selected record disappears before dispatch,
    /// openSession's authoritative missing-session error wins.
    func continueLatestSession(
        agent: AgentKind,
        projectCWD: String?
    ) async throws -> LaunchDestination {
        await ensureReady()
        guard SpotionSettings.enabledAgents.contains(agent),
              let selected = await store.latest(agent: agent, projectCWD: projectCWD) else {
            throw SpotionError.noMatchingSession(agent: agent, projectCWD: projectCWD)
        }
        return try await openSession(id: selected.id)
    }

    /// Resolve the exact current store record, then fork it through the
    /// terminal CLI. This does not consult or change the native-app preference
    /// because the native deep links have no explicit fork semantics.
    func forkSession(id: String) async throws -> TerminalApp {
        await ensureReady()
        guard let record = await store.record(id: id) else {
            throw SpotionError.sessionNotFound(id)
        }
        try await TerminalLauncher.shared.fork(record)
        return SpotionSettings.terminal
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
        await mergedProjects(limit: limit)
    }

    func matchingProjects(_ query: String, limit: Int) async -> [ProjectEntity] {
        await mergedProjects(matching: query, limit: limit)
    }

    /// Saved folders first (user order), then recent-session projects. A saved
    /// folder under an excluded project stays out of suggestions too — the
    /// exclusion rule is the user's stronger statement.
    private func mergedProjects(matching query: String? = nil, limit: Int) async -> [ProjectEntity] {
        await ensureReady()
        var saved: [SavedProject] = []
        for project in savedProjectStore.projects()
        where await !store.projectIsExcluded(cwd: project.path) {
            saved.append(project)
        }
        let recent = await store.distinctProjects()
        return QuickCreateProjectMerger.merge(
            saved: saved, recent: recent, matching: query, limit: limit
        ).map { ProjectEntity(id: $0.path, name: $0.name) }
    }

    // MARK: - Saved Quick Create projects

    func savedProjects() -> [SavedProject] {
        savedProjectStore.projects()
    }

    func savedProjectStorageWarning() -> String? {
        savedProjectStore.warning
    }

    func addSavedProject(path: String) throws {
        if try savedProjectStore.add(path) {
            SpotionShortcuts.updateAppShortcutParameters()
        }
    }

    func removeSavedProject(path: String) throws {
        if try savedProjectStore.remove(path) {
            SpotionShortcuts.updateAppShortcutParameters()
        }
    }

    func moveSavedProject(from source: Int, to destination: Int) throws {
        try savedProjectStore.move(from: source, to: destination)
        SpotionShortcuts.updateAppShortcutParameters()
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
