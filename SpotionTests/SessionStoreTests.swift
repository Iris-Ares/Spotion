import Foundation
import Testing

@Suite struct SessionStoreTests {
    struct Env {
        var codexHome: URL
        var claudeHome: URL
        var cacheURL: URL
    }

    private func makeEnv() throws -> Env {
        let root = try TestSupport.makeTempDir()
        return Env(
            codexHome: root.appendingPathComponent("codex"),
            claudeHome: root.appendingPathComponent("claude"),
            cacheURL: root.appendingPathComponent("cache/scan-cache.json"))
    }

    private func makeStore(_ env: Env) -> SessionStore {
        SessionStore(
            cacheURL: env.cacheURL,
            codexScanner: CodexScanner(codexHome: env.codexHome),
            claudeScanner: ClaudeScanner(claudeHome: env.claudeHome))
    }

    private func writeCodexSession(_ env: Env, title: String = "Codex 会话标题") throws {
        try TestSupport.write(
            [CodexScannerTests.meta(), CodexScannerTests.userMessage("codex prompt")].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))
        try TestSupport.write(
            "{\"id\":\"\(CodexScannerTests.uuid)\",\"thread_name\":\"\(title)\",\"updated_at\":\"2026-08-05T00:00:00Z\"}\n",
            to: env.codexHome.appendingPathComponent("session_index.jsonl"))
    }

    private func writeClaudeSession(_ env: Env, uuid: String = ClaudeScannerTests.uuid) throws {
        try TestSupport.write(
            [
                ClaudeScannerTests.user("claude prompt"),
                ClaudeScannerTests.customTitle("Claude 标题"),
            ].joined(separator: "\n") + "\n",
            to: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(uuid).jsonl"))
    }

    private let both: Set<AgentKind> = [.codex, .claude]

    @Test func refreshUpsertsThenStable() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        #expect(d1.upserts.count == 2)
        #expect(d1.deletedIDs.isEmpty)
        await store.markIndexed(d1)

        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.isEmpty)
    }

    /// Claude desktop's claude://resume import rewrites the transcript in
    /// place with the tail title records stripped — the previously parsed
    /// title must survive the rewrite instead of degrading to the first
    /// prompt.
    @Test func claudeTitleSurvivesTitleStrippingRewrite() async throws {
        let env = try makeEnv()
        try writeClaudeSession(env)  // carries custom title "Claude 标题"

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        try TestSupport.write(
            ClaudeScannerTests.user("rewritten by desktop import, no title records") + "\n",
            to: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl"))
        let d2 = await store.refresh(enabledAgents: both)

        let record = try #require(d2.upserts.first { $0.id == "claude:\(ClaudeScannerTests.uuid)" })
        #expect(record.fallbackTitle == "Claude 标题")
        let titled = await store.titled(records: [record])
        #expect(titled.first?.title == "Claude 标题")
    }

    @Test func deletionDetected() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)
        let secondUuid = "bbbbcccc-1122-3344-5566-77889900aabb"
        try writeClaudeSession(env, uuid: secondUuid)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        try FileManager.default.removeItem(
            at: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(secondUuid).jsonl"))
        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.deletedIDs == ["claude:\(secondUuid)"])
    }

    @Test func codexTitleChangeTriggersReindex() async throws {
        let env = try makeEnv()
        try writeCodexSession(env, title: "旧标题")

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        try writeCodexSession(env, title: "改过的标题")
        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        let record = try #require(await store.record(id: "codex:\(CodexScannerTests.uuid)"))
        #expect(await store.displayTitle(for: record) == "改过的标题")
    }

    @Test func cachePersistenceRoundtrip() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)

        let store1 = makeStore(env)
        await store1.bootstrap()
        let d1 = await store1.refresh(enabledAgents: both)
        await store1.markIndexed(d1)

        let store2 = makeStore(env)
        await store2.bootstrap()
        let d2 = await store2.refresh(enabledAgents: both)
        #expect(d2.isEmpty)
        let stats = await store2.lastStats
        #expect(stats.codexCount == 1)
        #expect(stats.claudeCount == 1)
    }

    @Test func displayTitlePriorities() async throws {
        let env = try makeEnv()
        try writeCodexSession(env, title: "索引里的标题")
        try writeClaudeSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)

        let codex = try #require(await store.record(id: "codex:\(CodexScannerTests.uuid)"))
        #expect(await store.displayTitle(for: codex) == "索引里的标题")
        let claude = try #require(await store.record(id: "claude:\(ClaudeScannerTests.uuid)"))
        #expect(await store.displayTitle(for: claude) == "Claude 标题")
    }

    @Test func codexTitleRemovalTriggersReindex() async throws {
        // A title entry vanished from session_index.jsonl → the session must be
        // re-donated (otherwise Spotlight keeps the stale title)
        let env = try makeEnv()
        try writeCodexSession(env, title: "会被移除的标题")

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        try TestSupport.write("", to: env.codexHome.appendingPathComponent("session_index.jsonl"))
        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        let record = try #require(await store.record(id: "codex:\(CodexScannerTests.uuid)"))
        #expect(await store.displayTitle(for: record) == "codex prompt")  // falls back to the first prompt
    }

    @Test func titleIndexReadFailurePreservesTitles() async throws {
        // session_index.jsonl temporarily unreadable → keep the old titles; must
        // not be treated as "all titles cleared" with a mass re-donation
        let env = try makeEnv()
        try writeCodexSession(env, title: "原标题")

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        let indexURL = env.codexHome.appendingPathComponent("session_index.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: indexURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexURL.path)
        }

        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.isEmpty)
        let record = try #require(await store.record(id: "codex:\(CodexScannerTests.uuid)"))
        #expect(await store.displayTitle(for: record) == "原标题")
    }

    @Test func markDirtyForcesUpsertAndReportsUnknown() async throws {
        // System-requested reindex: known ids force an upsert (even with
        // unchanged files), unknown ids are returned as-is
        let env = try makeEnv()
        try writeCodexSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)
        #expect(await store.refresh(enabledAgents: both).isEmpty)

        let known = "codex:\(CodexScannerTests.uuid)"
        let unknown = await store.markDirty(ids: [known, "codex:ghost"])
        #expect(unknown == ["codex:ghost"])
        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.upserts.map(\.id) == [known])
    }

    @Test func emptyRootDeletesLastSession() async throws {
        // The root enumerates successfully but holds no session files ([] not
        // nil) → the last session must be deleted from the index
        let env = try makeEnv()
        try writeClaudeSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        try FileManager.default.removeItem(
            at: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl"))
        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.deletedIDs == ["claude:\(ClaudeScannerTests.uuid)"])
    }

    @Test func enumerationFailurePreservesEntries() async throws {
        // The root is unreadable (enumeration fails with nil) → protective
        // retention, no deletions
        let env = try makeEnv()
        try writeClaudeSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        let projectsRoot = env.claudeHome.appendingPathComponent("projects")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projectsRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectsRoot.path)
        }

        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.deletedIDs.isEmpty)
        #expect(await store.record(id: "claude:\(ClaudeScannerTests.uuid)") != nil)
    }

    @Test func failedDonationRetriesChangedSession() async throws {
        // Indexed session content changed → donation fails (markIndexed not
        // called) → the next refresh must report the id again
        let env = try makeEnv()
        try writeCodexSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        // Append content (mtime+size change)
        let path = env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel)
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((CodexScannerTests.userMessage("更新") + "\n").utf8))
        try handle.close()

        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        // Simulate a donation failure: skip markIndexed

        let d3 = await store.refresh(enabledAgents: both)
        #expect(d3.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        await store.markIndexed(d3)

        let d4 = await store.refresh(enabledAgents: both)
        #expect(d4.isEmpty)
    }

    @Test func duplicateSessionIDNewestFileWins() async throws {
        // codex resume/fork create multiple rollout files for the same
        // session_id: the newest mtime wins; deleting the newest falls back to
        // the older file instead of losing the session
        let env = try makeEnv()
        let oldRel = "sessions/2026/08/01/rollout-2026-08-01T10-00-00-\(CodexScannerTests.uuid).jsonl"
        let newRel = "sessions/2026/08/05/rollout-2026-08-05T10-00-00-\(CodexScannerTests.uuid).jsonl"
        let content = [CodexScannerTests.meta(), CodexScannerTests.userMessage("x")].joined(separator: "\n") + "\n"
        let oldURL = try TestSupport.write(content, to: env.codexHome.appendingPathComponent(oldRel))
        let newURL = try TestSupport.write(content, to: env.codexHome.appendingPathComponent(newRel))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: newURL.path)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: [.codex])
        #expect(d1.upserts.count == 1)
        // Path assertions compare suffixes: /var and /private/var are two
        // symlink spellings of the same location
        var record = try #require(await store.record(id: "codex:\(CodexScannerTests.uuid)"))
        #expect(record.filePath.hasSuffix(newRel))
        await store.markIndexed(d1)

        try FileManager.default.removeItem(at: newURL)
        let d2 = await store.refresh(enabledAgents: [.codex])
        #expect(d2.deletedIDs.isEmpty)
        // Winner file deleted → the fallback file must be re-donated
        // (corrects the metadata Spotlight holds)
        #expect(d2.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        record = try #require(await store.record(id: "codex:\(CodexScannerTests.uuid)"))
        #expect(record.filePath.hasSuffix(oldRel))
        await store.markIndexed(d2)
        let d3 = await store.refresh(enabledAgents: [.codex])
        #expect(d3.isEmpty)
    }

    @Test func corruptedWinnerFallsBackAndRedonates() async throws {
        // The winning rollout of a duplicated session id changes and stops
        // parsing → the old id must be marked changed so the fallback file is
        // re-donated, instead of Spotlight keeping the dead file's metadata
        let env = try makeEnv()
        let oldRel = "sessions/2026/08/01/rollout-2026-08-01T10-00-00-\(CodexScannerTests.uuid).jsonl"
        let newRel = "sessions/2026/08/05/rollout-2026-08-05T10-00-00-\(CodexScannerTests.uuid).jsonl"
        let content = [CodexScannerTests.meta(), CodexScannerTests.userMessage("x")].joined(separator: "\n") + "\n"
        let oldURL = try TestSupport.write(content, to: env.codexHome.appendingPathComponent(oldRel))
        let newURL = try TestSupport.write(content, to: env.codexHome.appendingPathComponent(newRel))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: oldURL.path)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: [.codex])
        await store.markIndexed(d1)

        // Corrupt the winner (mtime+size change, now parses to nil)
        try TestSupport.write("NOT JSON — corrupted rollout data", to: newURL)
        let d2 = await store.refresh(enabledAgents: [.codex])
        #expect(d2.deletedIDs.isEmpty)
        #expect(d2.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        let record = try #require(await store.record(id: "codex:\(CodexScannerTests.uuid)"))
        #expect(record.filePath.hasSuffix(oldRel))
    }

    @Test func staleCacheFileTriggersFullRebuild() async throws {
        // A cache file exists but is outdated/corrupt → the old indexedIDs are
        // gone, so a deleteAll + full re-donation must be requested
        let env = try makeEnv()
        try TestSupport.write(
            "{\"version\":1,\"entries\":{},\"indexedIDs\":[\"codex:stale\"],\"codexTitles\":{}}",
            to: env.cacheURL)
        let store = makeStore(env)
        await store.bootstrap()
        #expect(await store.consumePendingFullRebuild() == true)
        #expect(await store.consumePendingFullRebuild() == false)  // consumed only once

        // A fresh environment (no cache file) must not trigger a rebuild
        let freshEnv = try makeEnv()
        let freshStore = makeStore(freshEnv)
        await freshStore.bootstrap()
        #expect(await freshStore.consumePendingFullRebuild() == false)

        // Corruption (non-JSON) triggers it as well
        let corruptEnv = try makeEnv()
        try TestSupport.write("NOT JSON AT ALL", to: corruptEnv.cacheURL)
        let corruptStore = makeStore(corruptEnv)
        await corruptStore.bootstrap()
        #expect(await corruptStore.consumePendingFullRebuild() == true)
    }

    @Test func transientReadFailureDoesNotEvict() async throws {
        // The file changed and is then temporarily unreadable: the I/O failure
        // must not be cached with the fresh mtime, or the session would be
        // evicted and never re-parsed once access is restored
        let env = try makeEnv()
        try writeClaudeSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        let fileURL = env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl")
        // Change the content, then make it unreadable
        try TestSupport.write(
            [ClaudeScannerTests.user("updated prompt"), ClaudeScannerTests.customTitle("新标题")]
                .joined(separator: "\n") + "\n",
            to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)

        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.deletedIDs.isEmpty)
        #expect(await store.record(id: "claude:\(ClaudeScannerTests.uuid)") != nil)

        // Access restored, file unchanged since: the stale cached mtime must
        // trigger a re-parse that picks up the new content
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let d3 = await store.refresh(enabledAgents: both)
        #expect(d3.upserts.map(\.id) == ["claude:\(ClaudeScannerTests.uuid)"])
        let record = try #require(await store.record(id: "claude:\(ClaudeScannerTests.uuid)"))
        #expect(record.fallbackTitle == "新标题")
    }

    @Test func ghostDeletionsPersistUntilCleared() async throws {
        // Queued ghost deletions must survive a restart and clear only when
        // the deletion is confirmed
        let env = try makeEnv()
        try writeCodexSession(env)

        let store1 = makeStore(env)
        await store1.bootstrap()
        _ = await store1.refresh(enabledAgents: both)
        await store1.addPendingGhostDeletions(["codex:ghost-1", "codex:ghost-2"])

        let store2 = makeStore(env)
        await store2.bootstrap()
        #expect(Set(await store2.pendingGhostDeletions()) == ["codex:ghost-1", "codex:ghost-2"])
        await store2.clearGhostDeletions(["codex:ghost-1"])

        let store3 = makeStore(env)
        await store3.bootstrap()
        #expect(await store3.pendingGhostDeletions() == ["codex:ghost-2"])
    }

    @Test func disablingAgentRemovesItsRecords() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        let d2 = await store.refresh(enabledAgents: [.codex])
        #expect(d2.deletedIDs == ["claude:\(ClaudeScannerTests.uuid)"])
    }
}
