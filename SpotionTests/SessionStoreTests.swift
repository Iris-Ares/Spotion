import Foundation
import Testing

@Suite struct SessionStoreTests {
    struct Env {
        var codexHome: URL
        var claudeHome: URL
        var cacheURL: URL
        var hiddenSessionsURL: URL
        var projectExclusionsURL: URL
    }

    private func makeEnv() throws -> Env {
        let root = try TestSupport.makeTempDir()
        return Env(
            codexHome: root.appendingPathComponent("codex"),
            claudeHome: root.appendingPathComponent("claude"),
            cacheURL: root.appendingPathComponent("cache/scan-cache.json"),
            hiddenSessionsURL: root.appendingPathComponent("state/hidden-sessions.json"),
            projectExclusionsURL: root.appendingPathComponent("state/project-exclusions.json"))
    }

    private func makeStore(_ env: Env) -> SessionStore {
        SessionStore(
            cacheURL: env.cacheURL,
            hiddenSessionsURL: env.hiddenSessionsURL,
            projectExclusionsURL: env.projectExclusionsURL,
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

    private func writeClaudeSession(
        _ env: Env,
        uuid: String = ClaudeScannerTests.uuid,
        title: String = "Claude 标题"
    ) throws {
        try TestSupport.write(
            [
                ClaudeScannerTests.user("claude prompt"),
                ClaudeScannerTests.customTitle(title),
            ].joined(separator: "\n") + "\n",
            to: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(uuid).jsonl"))
    }

    @discardableResult
    private func writeCodexSelectionFixture(
        _ env: Env,
        id: String,
        cwd: String,
        day: String,
        mtime: Date
    ) throws -> URL {
        let relative = "sessions/2026/08/\(day)/rollout-2026-08-\(day)T10-00-00-\(id).jsonl"
        let url = try TestSupport.write(
            [
                CodexScannerTests.meta(cwd: cwd, id: id),
                CodexScannerTests.userMessage("selection fixture"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(relative)
        )
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    private func writeClaudeSelectionFixture(
        _ env: Env,
        id: String,
        cwd: String,
        mtime: Date
    ) throws -> URL {
        let url = try TestSupport.write(
            ClaudeScannerTests.user("selection fixture", cwd: cwd) + "\n",
            to: env.claudeHome.appendingPathComponent("projects/selection/\(id).jsonl")
        )
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private let both: Set<AgentKind> = [.codex, .claude]

    private func setActivity(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

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

    @Test func exactSessionIDSearchAndKeywords() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)

        let codexID = CodexScannerTests.uuid
        let stableID = "codex:\(codexID)"
        let rawMatches = await store.all(matching: codexID.uppercased())
        #expect(rawMatches.map(\.id) == [stableID])
        let prefixedMatches = await store.all(matching: stableID.uppercased())
        #expect(prefixedMatches.map(\.id) == [stableID])
        #expect(await store.all(matching: "claude:\(codexID)").isEmpty)
        #expect(await store.all(matching: String(codexID.prefix(8))).isEmpty)
        #expect(await store.all(matching: "00000000-0000-0000-0000-000000000000").isEmpty)

        let record = try #require(await store.record(id: stableID))
        #expect(record.sessionID == codexID)
        let keywords = record.spotlightKeywords()
        #expect(keywords.count(where: { $0 == codexID }) == 1)
        #expect(keywords.count(where: { $0 == stableID }) == 1)
        #expect(keywords.contains(record.projectName))
        #expect(keywords.contains(record.agent.displayName))
        #expect(keywords.contains(record.agent.rawValue))
        #expect(keywords.contains("session"))
        #expect(keywords.contains((record.cwd as NSString).lastPathComponent))
        #expect(!record.spotlightContentDescription(includeLaterPrompts: true).contains(codexID))
        #expect(!(await store.displayTitle(for: record)).contains(codexID))
        #expect(!(await store.scanReport()).contains(codexID))
    }

    @Test func rawSessionIDSearchReturnsBothAgentsWhilePrefixDisambiguates() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env, uuid: CodexScannerTests.uuid)

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)

        let rawID = CodexScannerTests.uuid
        let rawMatches = Set(await store.all(matching: rawID).map(\.id))
        #expect(rawMatches == ["codex:\(rawID)", "claude:\(rawID)"])
        #expect(await store.all(matching: "codex:\(rawID)").map(\.id) == ["codex:\(rawID)"])
        #expect(await store.all(matching: "claude:\(rawID)").map(\.id) == ["claude:\(rawID)"])
    }

    @Test func donatedContentGenerationRedonatesOnceAndRetries() async throws {
        #expect(DonatedContentGeneration.requiresFullRebuild(stored: 3))
        #expect(!DonatedContentGeneration.requiresFullRebuild(stored: DonatedContentGeneration.current))

        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)
        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        let stableIDs = Set(initial.upserts.map(\.id))
        await store.markIndexed(initial)
        #expect(await store.refresh(enabledAgents: both).isEmpty)

        await store.forgetIndexed()
        let migration = await store.refresh(enabledAgents: both)
        #expect(Set(migration.upserts.map(\.id)) == stableIDs)

        let retry = await store.refresh(enabledAgents: both)
        #expect(Set(retry.upserts.map(\.id)) == stableIDs)
        await store.markIndexed(retry)
        #expect(await store.refresh(enabledAgents: both).isEmpty)
    }

    @Test func togglingLaterPromptSearchRedonatesOnceThenStabilizes() async throws {
        let env = try makeEnv()
        try TestSupport.write(
            [
                CodexScannerTests.meta(),
                CodexScannerTests.userMessage("codex first"),
                CodexScannerTests.userMessage("codex distinctive later phrase"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))
        try TestSupport.write(
            [
                ClaudeScannerTests.user("claude first"),
                ClaudeScannerTests.user("claude distinctive later phrase"),
            ].joined(separator: "\n") + "\n",
            to: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl"))

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both, includeLaterPrompts: false)
        #expect(initial.upserts.count == 2)
        #expect(initial.upserts.allSatisfy { $0.laterPromptSnippets.isEmpty })
        await store.markIndexed(initial)
        #expect(await store.refresh(enabledAgents: both, includeLaterPrompts: false).isEmpty)

        let enabled = await store.refresh(enabledAgents: both, includeLaterPrompts: true)
        #expect(enabled.upserts.count == 2)
        #expect(enabled.upserts.contains { $0.laterPromptSnippets == ["codex distinctive later phrase"] })
        #expect(enabled.upserts.contains { $0.laterPromptSnippets == ["claude distinctive later phrase"] })
        await store.markIndexed(enabled)
        #expect(await store.refresh(enabledAgents: both, includeLaterPrompts: true).isEmpty)
        let persistedCache = try String(contentsOf: env.cacheURL, encoding: .utf8)
        #expect(!persistedCache.contains("distinctive later phrase"))

        // A full rebuild after relaunch must hydrate the non-persisted prompt
        // snippets before donating every record again.
        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        await relaunched.forgetIndexed()
        let rebuilt = await relaunched.refresh(enabledAgents: both, includeLaterPrompts: true)
        #expect(rebuilt.upserts.count == 2)
        #expect(rebuilt.upserts.contains { $0.laterPromptSnippets == ["codex distinctive later phrase"] })
        #expect(rebuilt.upserts.contains { $0.laterPromptSnippets == ["claude distinctive later phrase"] })

        let disabled = await store.refresh(enabledAgents: both, includeLaterPrompts: false)
        #expect(disabled.upserts.count == 2)
        #expect(disabled.upserts.allSatisfy { $0.laterPromptSnippets.isEmpty })
        #expect(disabled.upserts.allSatisfy {
            !$0.spotlightContentDescription(includeLaterPrompts: false).contains("distinctive later phrase")
        })
        await store.markIndexed(disabled)
        #expect(await store.refresh(enabledAgents: both, includeLaterPrompts: false).isEmpty)
    }

    @Test func disablingLaterPromptSearchAfterRelaunchRedonatesCachedSessions() async throws {
        let env = try makeEnv()
        try TestSupport.write(
            [
                CodexScannerTests.meta(),
                CodexScannerTests.userMessage("first prompt"),
                CodexScannerTests.userMessage("private later phrase"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both, includeLaterPrompts: false)
        await store.markIndexed(initial)
        let enabled = await store.refresh(enabledAgents: both, includeLaterPrompts: true)
        #expect(enabled.upserts.count == 1)
        await store.markIndexed(enabled)

        // Prompt snippets are intentionally absent from the persisted cache,
        // but disabling after relaunch must still overwrite Spotlight metadata.
        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        let disabled = await relaunched.refresh(enabledAgents: both, includeLaterPrompts: false)
        #expect(disabled.upserts.count == 1)
        #expect(disabled.upserts.allSatisfy { $0.laterPromptSnippets.isEmpty })
        #expect(disabled.upserts.allSatisfy {
            !$0.spotlightContentDescription(includeLaterPrompts: false).contains("private later phrase")
        })
    }

    @Test func preGitBranchCacheReparsesAndUpsertsOnce() async throws {
        let env = try makeEnv()
        let sessionURL = try TestSupport.write(
            [
                CodexScannerTests.meta(extra: ",\"git\":{\"branch\":\"feature/cache-migration\"}"),
                CodexScannerTests.userMessage("cached prompt"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))
        let values = try sessionURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = try #require(values.contentModificationDate)
        let size = Int64(try #require(values.fileSize))

        var legacyRecord = try #require(CodexScanner(codexHome: env.codexHome)
            .parse(ScannedFile(path: sessionURL.path, mtime: mtime, size: size)).record)
        legacyRecord.gitBranch = nil
        var legacyCache = ScanCache()
        legacyCache.version = 6
        legacyCache.entries[sessionURL.path] = ScanCacheEntry(
            mtime: mtime, size: size, record: legacyRecord)
        legacyCache.indexedIDs = [legacyRecord.id]
        let cacheData = try JSONEncoder().encode(legacyCache)
        try TestSupport.write(String(decoding: cacheData, as: UTF8.self), to: env.cacheURL)

        let store = makeStore(env)
        await store.bootstrap()
        #expect(await store.consumePendingFullRebuild())

        let migrated = await store.refresh(enabledAgents: [.codex])
        let record = try #require(migrated.upserts.first)
        #expect(migrated.upserts.count == 1)
        #expect(record.gitBranch == "feature/cache-migration")
        await store.markIndexed(migrated)
        #expect(await store.refresh(enabledAgents: [.codex]).isEmpty)
    }

    @Test func togglingTouchedFileSearchHydratesTransientPathsAndStabilizes() async throws {
        let env = try makeEnv()
        try TestSupport.write(
            [
                CodexScannerTests.meta(),
                CodexScannerTests.userMessage("codex first"),
                try CodexScannerTests.fileToolCall("edit_file", path: "/tmp/proj/Sources/Auth.swift"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))
        try TestSupport.write(
            [
                ClaudeScannerTests.user("claude first"),
                try ClaudeScannerTests.fileToolUse("Write", path: "Tests/LoginTests.swift"),
            ].joined(separator: "\n") + "\n",
            to: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl"))

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both, includeTouchedFiles: false)
        #expect(initial.upserts.count == 2)
        #expect(initial.upserts.allSatisfy { $0.touchedFilePaths.isEmpty })
        await store.markIndexed(initial)
        #expect(await store.refresh(enabledAgents: both, includeTouchedFiles: false).isEmpty)

        let enabled = await store.refresh(enabledAgents: both, includeTouchedFiles: true)
        #expect(enabled.upserts.count == 2)
        #expect(enabled.upserts.contains { $0.touchedFilePaths == ["Sources/Auth.swift"] })
        #expect(enabled.upserts.contains { $0.touchedFilePaths == ["Tests/LoginTests.swift"] })

        // Simulate a failed donation. Transient paths must be rehydrated and
        // retried even though they were deliberately absent from the cache.
        let retried = await store.refresh(enabledAgents: both, includeTouchedFiles: true)
        #expect(retried.upserts.count == 2)
        #expect(retried.upserts.allSatisfy { !$0.touchedFilePaths.isEmpty })
        await store.markIndexed(retried)
        #expect(await store.refresh(enabledAgents: both, includeTouchedFiles: true).isEmpty)

        let persistedCache = try String(contentsOf: env.cacheURL, encoding: .utf8)
        #expect(!persistedCache.contains("Sources/Auth.swift"))
        #expect(!persistedCache.contains("Tests/LoginTests.swift"))

        // A full rebuild after relaunch must hydrate paths before donation.
        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        await relaunched.forgetIndexed()
        let rebuilt = await relaunched.refresh(enabledAgents: both, includeTouchedFiles: true)
        #expect(rebuilt.upserts.count == 2)
        #expect(rebuilt.upserts.allSatisfy { !$0.touchedFilePaths.isEmpty })

        let disabled = await store.refresh(enabledAgents: both, includeTouchedFiles: false)
        #expect(disabled.upserts.count == 2)
        #expect(disabled.upserts.allSatisfy { $0.touchedFilePaths.isEmpty })
        #expect(disabled.upserts.allSatisfy {
            !$0.spotlightKeywords(includeTouchedFiles: false).contains("Auth.swift")
        })
        await store.markIndexed(disabled)
        #expect(await store.refresh(enabledAgents: both, includeTouchedFiles: false).isEmpty)
    }

    @Test func touchedFileGenerationChangeReparsesUnchangedSessionsOnce() async throws {
        let env = try makeEnv()
        try TestSupport.write(
            [
                CodexScannerTests.meta(),
                CodexScannerTests.userMessage("first"),
                try CodexScannerTests.fileToolCall("read_file", path: "Sources/Generation.swift"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both, includeTouchedFiles: true)
        await store.markIndexed(initial)

        // Simulate an older extraction generation while preserving the rest of
        // the valid cache, including indexedIDs and unchanged file metadata.
        let cached = try String(contentsOf: env.cacheURL, encoding: .utf8)
        let olderGeneration = cached.replacingOccurrences(
            of: "\"touchedFileExtractionGeneration\":\(TouchedFilePolicy.extractionGeneration)",
            with: "\"touchedFileExtractionGeneration\":0"
        )
        #expect(olderGeneration != cached)
        try olderGeneration.write(to: env.cacheURL, atomically: true, encoding: .utf8)

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        let migrated = await relaunched.refresh(enabledAgents: both, includeTouchedFiles: true)
        #expect(migrated.upserts.count == 1)
        #expect(migrated.upserts.first?.touchedFilePaths == ["Sources/Generation.swift"])
        await relaunched.markIndexed(migrated)
        #expect(await relaunched.refresh(enabledAgents: both, includeTouchedFiles: true).isEmpty)
    }

    @Test func disablingTouchedFileSearchAfterRelaunchRedonatesCachedSessions() async throws {
        let env = try makeEnv()
        try TestSupport.write(
            [
                CodexScannerTests.meta(),
                CodexScannerTests.userMessage("first"),
                try CodexScannerTests.fileToolCall("read_file", path: "Sources/PrivatePath.swift"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))

        let store = makeStore(env)
        await store.bootstrap()
        let enabled = await store.refresh(enabledAgents: both, includeTouchedFiles: true)
        await store.markIndexed(enabled)

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        let disabled = await relaunched.refresh(enabledAgents: both, includeTouchedFiles: false)
        #expect(disabled.upserts.count == 1)
        #expect(disabled.upserts.first?.touchedFilePaths.isEmpty == true)
        #expect(disabled.upserts.first?.spotlightKeywords(includeTouchedFiles: false).contains("PrivatePath.swift") == false)
    }

    @Test func touchedFileHydrationSurvivesTransientEnumerationFailure() async throws {
        let env = try makeEnv()
        try TestSupport.write(
            [
                ClaudeScannerTests.user("first"),
                try ClaudeScannerTests.fileToolUse("Read", path: "Sources/Eventually.swift"),
            ].joined(separator: "\n") + "\n",
            to: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl"))

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: [.claude], includeTouchedFiles: false)
        await store.markIndexed(initial)

        let root = env.claudeHome.appendingPathComponent("projects")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        let deferred = await store.refresh(enabledAgents: [.claude], includeTouchedFiles: true)
        #expect(deferred.isEmpty)
        #expect(await store.record(id: "claude:\(ClaudeScannerTests.uuid)") != nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let hydrated = await store.refresh(enabledAgents: [.claude], includeTouchedFiles: true)
        #expect(hydrated.upserts.first?.touchedFilePaths == ["Sources/Eventually.swift"])
    }

    @Test func touchedFilesFollowDuplicateRolloutWinnerWithoutDelay() async throws {
        let env = try makeEnv()
        let oldRel = "sessions/2026/08/01/rollout-old-\(CodexScannerTests.uuid).jsonl"
        let newRel = "sessions/2026/08/05/rollout-new-\(CodexScannerTests.uuid).jsonl"
        let oldURL = try TestSupport.write(
            [
                CodexScannerTests.meta(),
                CodexScannerTests.userMessage("old"),
                try CodexScannerTests.fileToolCall("read_file", path: "Sources/Old.swift"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(oldRel))
        let newURL = try TestSupport.write(
            [
                CodexScannerTests.meta(),
                CodexScannerTests.userMessage("new"),
                try CodexScannerTests.fileToolCall("read_file", path: "Sources/New.swift"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(newRel))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_400)],
            ofItemAtPath: oldURL.path)

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: [.codex], includeTouchedFiles: true)
        #expect(initial.upserts.first?.touchedFilePaths == ["Sources/New.swift"])
        await store.markIndexed(initial)

        try FileManager.default.removeItem(at: newURL)
        let fallback = await store.refresh(enabledAgents: [.codex], includeTouchedFiles: true)
        #expect(fallback.deletedIDs.isEmpty)
        #expect(fallback.upserts.first?.touchedFilePaths == ["Sources/Old.swift"])
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

    @Test func latestSelectionIsAgentScopedAndUsesNormalizedExactProject() async throws {
        let env = try makeEnv()
        let base = Date(timeIntervalSince1970: 1_000)
        let projectOld = "10000000-0000-0000-0000-000000000001"
        let projectNew = "20000000-0000-0000-0000-000000000002"
        let siblingNewer = "30000000-0000-0000-0000-000000000003"
        let claudeNewest = "40000000-0000-0000-0000-000000000004"

        try writeCodexSelectionFixture(
            env, id: projectOld, cwd: "/tmp/work/project", day: "01", mtime: base)
        try writeCodexSelectionFixture(
            env, id: projectNew, cwd: "/tmp/work/./project/", day: "02",
            mtime: base.addingTimeInterval(10))
        try writeCodexSelectionFixture(
            env, id: siblingNewer, cwd: "/tmp/work/project-old", day: "03",
            mtime: base.addingTimeInterval(20))
        try writeClaudeSelectionFixture(
            env, id: claudeNewest, cwd: "/tmp/work/project", mtime: base.addingTimeInterval(30))

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)

        #expect(await store.latest(agent: .codex, projectCWD: nil)?.sessionID == siblingNewer)
        #expect(await store.latest(
            agent: .codex, projectCWD: "/tmp/work/project"
        )?.sessionID == projectNew)
        #expect(await store.latest(
            agent: .claude, projectCWD: "/tmp/work/./project/"
        )?.sessionID == claudeNewest)
        #expect(await store.latest(agent: .claude, projectCWD: "/tmp/work/project-old") == nil)
    }

    @Test func latestSelectionUsesAscendingSessionIDForTimestampTies() async throws {
        let env = try makeEnv()
        let tied = Date(timeIntervalSince1970: 2_000)
        let smaller = "10000000-0000-0000-0000-000000000001"
        let larger = "90000000-0000-0000-0000-000000000009"
        try writeCodexSelectionFixture(
            env, id: larger, cwd: "/tmp/project", day: "01", mtime: tied)
        try writeCodexSelectionFixture(
            env, id: smaller, cwd: "/tmp/project", day: "02", mtime: tied)

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: [.codex])

        #expect(await store.latest(agent: .codex, projectCWD: nil)?.sessionID == smaller)
        #expect(await store.latest(agent: .claude, projectCWD: nil) == nil)
        #expect(await store.latest(agent: .codex, projectCWD: "/tmp/missing") == nil)
    }

    @Test func selectedRecordRemovalMakesExactLaunchLookupFail() async throws {
        let env = try makeEnv()
        let id = "50000000-0000-0000-0000-000000000005"
        let url = try writeCodexSelectionFixture(
            env, id: id, cwd: "/tmp/project", day: "01", mtime: Date())

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: [.codex])
        let selected = try #require(await store.latest(agent: .codex, projectCWD: nil))

        try FileManager.default.removeItem(at: url)
        _ = await store.refresh(enabledAgents: [.codex])

        #expect(await store.record(id: selected.id) == nil)
        #expect(await store.latest(agent: .codex, projectCWD: nil) == nil)
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

    @Test func iconSourceChangeRedonatesAgentSessions() async throws {
        // Donated thumbnails embed the handler app's icon: a fingerprint drift
        // (app installed/removed/replaced) must re-donate every session of the
        // agent even though the session files are unchanged
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)
        let secondUuid = "bbbbcccc-1122-3344-5566-77889900aabb"
        try writeClaudeSession(env, uuid: secondUuid)

        let store = makeStore(env)
        await store.bootstrap()
        let v1: [AgentKind: String] = [.codex: "codex-v1", .claude: ""]
        let d1 = await store.refresh(enabledAgents: both, iconSources: v1)
        #expect(d1.upserts.count == 3)
        await store.markIndexed(d1)

        // Unchanged fingerprints → no churn
        let d2 = await store.refresh(enabledAgents: both, iconSources: v1)
        #expect(d2.isEmpty)

        // Claude desktop app appeared → both claude sessions re-donate, codex untouched
        let v2: [AgentKind: String] = [.codex: "codex-v1", .claude: "/Applications/Claude.app|123"]
        let d3 = await store.refresh(enabledAgents: both, iconSources: v2)
        #expect(Set(d3.upserts.map(\.id)) == ["claude:\(ClaudeScannerTests.uuid)", "claude:\(secondUuid)"])

        // Simulate a donation failure (no markIndexed): the obligation lives
        // in dirtyIDs and must survive even though the stored fingerprint
        // already advanced
        let d4 = await store.refresh(enabledAgents: both, iconSources: v2)
        #expect(Set(d4.upserts.map(\.id)) == ["claude:\(ClaudeScannerTests.uuid)", "claude:\(secondUuid)"])
        await store.markIndexed(d4)

        // Fingerprints persist in the scan cache across restarts
        let store2 = makeStore(env)
        await store2.bootstrap()
        let d5 = await store2.refresh(enabledAgents: both, iconSources: v2)
        #expect(d5.isEmpty)
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

    @Test func hiddenSessionIsExcludedAndMutationRetriesAcrossRelaunch() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)
        let codexID = "codex:\(CodexScannerTests.uuid)"
        let claudeID = "claude:\(ClaudeScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)

        #expect(try await store.hideSession(id: codexID))
        #expect(try await !store.hideSession(id: codexID))
        let hidden = await store.refresh(enabledAgents: both)
        #expect(hidden.upserts.isEmpty)
        #expect(hidden.deletedIDs == [codexID])
        #expect(await store.record(id: codexID) == nil)
        #expect(await store.allTitled(matching: "Codex").isEmpty)
        #expect(await store.allTitled().map(\.record.id) == [claudeID])
        let snapshots = await store.hiddenSessionSnapshots()
        #expect(snapshots.map(\.id) == [codexID])
        #expect(snapshots.first?.agent == .codex)
        #expect(snapshots.first?.projectName == "proj")
        #expect(await store.markDirty(ids: [codexID]) == [codexID])

        // Simulate a timed-out Spotlight deletion: without markIndexed, the
        // deletion obligation must remain in the scan cache.
        let retry = await store.refresh(enabledAgents: both)
        #expect(retry.deletedIDs == [codexID])

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        let afterRelaunch = await relaunched.refresh(enabledAgents: both)
        #expect(afterRelaunch.deletedIDs == [codexID])
        await relaunched.markIndexed(afterRelaunch)
        #expect(await relaunched.refresh(enabledAgents: both).isEmpty)

        // Replacing the scan cache must not erase the independent hide list.
        let resetCacheStore = SessionStore(
            cacheURL: env.cacheURL.deletingLastPathComponent().appendingPathComponent("reset-cache.json"),
            hiddenSessionsURL: env.hiddenSessionsURL,
            projectExclusionsURL: env.projectExclusionsURL,
            codexScanner: CodexScanner(codexHome: env.codexHome),
            claudeScanner: ClaudeScanner(claudeHome: env.claudeHome))
        await resetCacheStore.bootstrap()
        let afterCacheReset = await resetCacheStore.refresh(enabledAgents: both)
        #expect(afterCacheReset.upserts.map(\.id) == [claudeID])

        // A full rebuild must still omit hidden sessions.
        await relaunched.forgetIndexed()
        let rebuild = await relaunched.refresh(enabledAgents: both)
        #expect(rebuild.upserts.map(\.id) == [claudeID])
        await relaunched.markIndexed(rebuild)

        #expect(try await relaunched.restoreSession(id: codexID))
        #expect(try await !relaunched.restoreSession(id: codexID))
        let restored = await relaunched.refresh(enabledAgents: both)
        #expect(restored.upserts.map(\.id) == [codexID])
        await relaunched.markIndexed(restored)
        #expect(await relaunched.refresh(enabledAgents: both).isEmpty)
    }

    @Test func hiddenSessionSurvivesAgentDisableAndPrunesAfterSourceDeletion() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)
        let codexID = "codex:\(CodexScannerTests.uuid)"
        let duplicateRel = "sessions/2026/08/13/rollout-duplicate-\(CodexScannerTests.uuid).jsonl"
        try TestSupport.write(
            [CodexScannerTests.meta(), CodexScannerTests.userMessage("duplicate rollout")]
                .joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(duplicateRel))

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)
        #expect(try await store.hideSession(id: codexID))
        let hideDiff = await store.refresh(enabledAgents: both)
        await store.markIndexed(hideDiff)

        // Disabling an agent removes its scan-cache entries, but that is not
        // evidence that its source transcript was deleted.
        _ = await store.refresh(enabledAgents: [.claude])
        #expect(await store.hiddenSessionSnapshots().map(\.id) == [codexID])

        let enabledAgain = await store.refresh(enabledAgents: both)
        #expect(!enabledAgain.upserts.contains { $0.id == codexID })
        #expect(await store.hiddenSessionSnapshots().map(\.id) == [codexID])

        try FileManager.default.removeItem(
            at: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))
        _ = await store.refresh(enabledAgents: both)
        #expect(await store.hiddenSessionSnapshots().map(\.id) == [codexID])

        try FileManager.default.removeItem(at: env.codexHome.appendingPathComponent(duplicateRel))
        _ = await store.refresh(enabledAgents: both)
        #expect(await store.hiddenSessionSnapshots().isEmpty)
    }

    @Test func hiddenSessionSurvivesCacheResetWhileSourceIsUnusable() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        let id = "codex:\(CodexScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)
        #expect(try await store.hideSession(id: id))
        let hidden = await store.refresh(enabledAgents: both)
        await store.markIndexed(hidden)

        try FileManager.default.removeItem(at: env.cacheURL)
        try TestSupport.write(
            "temporarily unusable transcript\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        _ = await relaunched.refresh(enabledAgents: both)
        #expect(await relaunched.hiddenSessionSnapshots().map(\.id) == [id])

        try writeCodexSession(env)
        let recovered = await relaunched.refresh(enabledAgents: both)
        #expect(!recovered.upserts.contains { $0.id == id })
        #expect(await relaunched.hiddenSessionSnapshots().map(\.id) == [id])
    }

    @Test func restoreRequiresDurableRedonationBeforeClearingHideState() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        let id = "codex:\(CodexScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)
        #expect(try await store.hideSession(id: id))
        let hidden = await store.refresh(enabledAgents: both)
        await store.markIndexed(hidden)

        // A directory at the cache file path makes the prerequisite atomic
        // cache write fail while the independent hide store remains writable.
        try FileManager.default.removeItem(at: env.cacheURL)
        try FileManager.default.createDirectory(at: env.cacheURL, withIntermediateDirectories: false)
        var restoreFailed = false
        do {
            _ = try await store.restoreSession(id: id)
        } catch {
            restoreFailed = true
        }
        #expect(restoreFailed)
        #expect(await store.hiddenSessionSnapshots().map(\.id) == [id])
    }

    @Test func historyWindowTargetsDiffsAndFiltersSessionQueriesWithoutRemovingCache() async throws {
        let env = try makeEnv()
        try writeCodexSession(env, title: "Old Codex title")
        try writeClaudeSession(env)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try setActivity(
            now.addingTimeInterval(-40 * 86_400),
            at: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel)
        )
        try setActivity(
            now.addingTimeInterval(-2 * 86_400),
            at: env.claudeHome.appendingPathComponent(
                "projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl")
        )

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both, historyWindow: .all, now: now)
        #expect(initial.upserts.count == 2)
        await store.markIndexed(initial)

        let shortened = await store.refresh(
            enabledAgents: both,
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(shortened.upserts.isEmpty)
        #expect(shortened.deletedIDs == ["codex:\(CodexScannerTests.uuid)"])
        #expect(await store.all().map(\.agent) == [.claude])
        #expect(await store.allTitled(matching: "Old Codex").isEmpty)
        #expect(await store.record(id: "codex:\(CodexScannerTests.uuid)") == nil)
        let stats = await store.lastStats
        #expect(stats.visibleCount == 1)
        #expect(stats.totalCount == 2)
        let persisted = try String(contentsOf: env.cacheURL, encoding: .utf8)
        #expect(persisted.contains("codex:\(CodexScannerTests.uuid)"))
        await store.markIndexed(shortened)
        #expect(await store.refresh(
            enabledAgents: both,
            historyWindow: .thirtyDays,
            now: now
        ).isEmpty)

        await store.forgetIndexed()
        let rebuilt = await store.refresh(
            enabledAgents: both,
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(rebuilt.upserts.map(\.agent) == [.claude])
        await store.markIndexed(rebuilt)

        let expanded = await store.refresh(
            enabledAgents: both,
            historyWindow: .ninetyDays,
            now: now
        )
        #expect(expanded.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        #expect(expanded.deletedIDs.isEmpty)
        await store.markIndexed(expanded)
        #expect(await store.refresh(
            enabledAgents: both,
            historyWindow: .ninetyDays,
            now: now
        ).isEmpty)
    }

    @Test func failedHistoryWindowMutationsRetryAcrossRelaunches() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try setActivity(
            now.addingTimeInterval(-40 * 86_400),
            at: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel)
        )
        try setActivity(
            now.addingTimeInterval(-2 * 86_400),
            at: env.claudeHome.appendingPathComponent(
                "projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl")
        )

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both, historyWindow: .all, now: now)
        await store.markIndexed(initial)

        let failedDelete = await store.refresh(
            enabledAgents: both,
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(failedDelete.deletedIDs == ["codex:\(CodexScannerTests.uuid)"])
        // Simulate a failed Spotlight deletion by not calling markIndexed.

        let relaunched = SessionStore(
            cacheURL: env.cacheURL,
            codexScanner: CodexScanner(codexHome: env.codexHome),
            claudeScanner: ClaudeScanner(claudeHome: env.claudeHome),
            historyWindow: .thirtyDays,
            now: now
        )
        await relaunched.bootstrap()
        let retriedDelete = await relaunched.refresh(
            enabledAgents: both,
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(retriedDelete.deletedIDs == failedDelete.deletedIDs)
        await relaunched.markIndexed(retriedDelete)

        let failedUpsert = await relaunched.refresh(
            enabledAgents: both,
            historyWindow: .ninetyDays,
            now: now
        )
        #expect(failedUpsert.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        // Simulate a failed re-donation by not calling markIndexed.

        let relaunchedAgain = SessionStore(
            cacheURL: env.cacheURL,
            codexScanner: CodexScanner(codexHome: env.codexHome),
            claudeScanner: ClaudeScanner(claudeHome: env.claudeHome),
            historyWindow: .ninetyDays,
            now: now
        )
        await relaunchedAgain.bootstrap()
        let retriedUpsert = await relaunchedAgain.refresh(
            enabledAgents: both,
            historyWindow: .ninetyDays,
            now: now
        )
        #expect(retriedUpsert.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
    }

    @Test func reindexRequestDeletesPolicyIneligibleCachedSession() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let id = "codex:\(CodexScannerTests.uuid)"
        try setActivity(
            now.addingTimeInterval(-40 * 86_400),
            at: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel)
        )

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: [.codex], historyWindow: .all, now: now)
        await store.markIndexed(initial)

        let shortened = await store.refresh(
            enabledAgents: [.codex],
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(shortened.deletedIDs == [id])
        await store.markIndexed(shortened)

        // The record remains in the scan cache by design, but a later system
        // reindex request must delete a stale Spotlight item rather than mark
        // the ineligible record dirty and then produce no mutation.
        #expect(await store.record(id: id) == nil)
        #expect(await store.markDirty(ids: [id]) == [id])
        await store.addPendingGhostDeletions([id])
        #expect(await store.pendingGhostDeletions() == [id])
        #expect(await store.refresh(
            enabledAgents: [.codex],
            historyWindow: .thirtyDays,
            now: now
        ).isEmpty)
    }

    @Test func genuineActivityMakesAnOldSessionEligibleAgain() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sessionURL = env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel)
        try setActivity(now.addingTimeInterval(-31 * 86_400), at: sessionURL)

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(
            enabledAgents: [.codex],
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(initial.isEmpty)
        #expect(await store.record(id: "codex:\(CodexScannerTests.uuid)") == nil)

        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((CodexScannerTests.userMessage("new activity") + "\n").utf8))
        try handle.close()
        try setActivity(now, at: sessionURL)

        let updated = await store.refresh(
            enabledAgents: [.codex],
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(updated.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        #expect(await store.record(id: "codex:\(CodexScannerTests.uuid)") != nil)
    }

    @Test func transientEnumerationFailureDefersAgeBasedDeletion() async throws {
        let env = try makeEnv()
        try writeClaudeSession(env)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sessionURL = env.claudeHome.appendingPathComponent(
            "projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl")
        try setActivity(now.addingTimeInterval(-31 * 86_400), at: sessionURL)

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: [.claude], historyWindow: .all, now: now)
        await store.markIndexed(initial)

        let projectsRoot = env.claudeHome.appendingPathComponent("projects")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projectsRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectsRoot.path)
        }

        let deferred = await store.refresh(
            enabledAgents: [.claude],
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(deferred.isEmpty)
        #expect(await store.record(id: "claude:\(ClaudeScannerTests.uuid)") != nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectsRoot.path)
        let confirmed = await store.refresh(
            enabledAgents: [.claude],
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(confirmed.deletedIDs == ["claude:\(ClaudeScannerTests.uuid)"])
    }

    @Test func duplicateRolloutFallsOutsideWindowWhenRecentWinnerDisappears() async throws {
        let env = try makeEnv()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldRel = "sessions/2026/08/01/rollout-old-\(CodexScannerTests.uuid).jsonl"
        let recentRel = "sessions/2026/08/05/rollout-recent-\(CodexScannerTests.uuid).jsonl"
        let content = [CodexScannerTests.meta(), CodexScannerTests.userMessage("x")]
            .joined(separator: "\n") + "\n"
        let oldURL = try TestSupport.write(content, to: env.codexHome.appendingPathComponent(oldRel))
        let recentURL = try TestSupport.write(content, to: env.codexHome.appendingPathComponent(recentRel))
        try setActivity(now.addingTimeInterval(-40 * 86_400), at: oldURL)
        try setActivity(now.addingTimeInterval(-2 * 86_400), at: recentURL)

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(
            enabledAgents: [.codex],
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(initial.upserts.count == 1)
        await store.markIndexed(initial)

        try FileManager.default.removeItem(at: recentURL)
        let fallback = await store.refresh(
            enabledAgents: [.codex],
            historyWindow: .thirtyDays,
            now: now
        )
        #expect(fallback.upserts.isEmpty)
        #expect(fallback.deletedIDs == ["codex:\(CodexScannerTests.uuid)"])
    }

    @Test func projectExclusionFiltersQueriesAndRetriesMutationsAcrossRelaunch() async throws {
        let env = try makeEnv()
        try TestSupport.write(
            [
                CodexScannerTests.meta(cwd: "/work/client/app"),
                CodexScannerTests.userMessage("client codex prompt"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))
        try TestSupport.write(
            [
                ClaudeScannerTests.user("sibling claude prompt", cwd: "/work/client-old"),
                ClaudeScannerTests.customTitle("Sibling session"),
            ].joined(separator: "\n") + "\n",
            to: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl"))
        let codexID = "codex:\(CodexScannerTests.uuid)"
        let claudeID = "claude:\(ClaudeScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)

        #expect(try await store.addProjectExclusion(path: "/work/client"))
        #expect(try await !store.addProjectExclusion(path: "/work/client/./"))
        let excluded = await store.refresh(enabledAgents: both)
        #expect(excluded.upserts.isEmpty)
        #expect(excluded.deletedIDs == [codexID])
        #expect(await store.record(id: codexID) == nil)
        #expect(await store.allTitled(matching: "client codex").isEmpty)
        #expect(await store.allTitled().map(\.record.id) == [claudeID])
        #expect(await store.distinctProjects().map(\.cwd) == ["/work/client-old"])
        #expect(await store.markDirty(ids: [codexID]) == [codexID])

        _ = await store.refresh(enabledAgents: [.claude])
        #expect(await store.projectExclusionList().map(\.path) == ["/work/client"])
        #expect(await store.refresh(enabledAgents: both).deletedIDs == [codexID])

        // A timed-out deletion remains retryable until markIndexed confirms it.
        #expect(await store.refresh(enabledAgents: both).deletedIDs == [codexID])
        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        let retry = await relaunched.refresh(enabledAgents: both)
        #expect(retry.deletedIDs == [codexID])
        await relaunched.markIndexed(retry)

        // A fresh scan cache and a full rebuild both retain the independent
        // project policy and donate only the sibling-prefix session.
        let resetCacheStore = SessionStore(
            cacheURL: env.cacheURL.deletingLastPathComponent().appendingPathComponent("reset-cache.json"),
            projectExclusionsURL: env.projectExclusionsURL,
            codexScanner: CodexScanner(codexHome: env.codexHome),
            claudeScanner: ClaudeScanner(claudeHome: env.claudeHome))
        await resetCacheStore.bootstrap()
        #expect(await resetCacheStore.refresh(enabledAgents: both).upserts.map(\.id) == [claudeID])
        await relaunched.forgetIndexed()
        let rebuild = await relaunched.refresh(enabledAgents: both)
        #expect(rebuild.upserts.map(\.id) == [claudeID])
        await relaunched.markIndexed(rebuild)

        // A watcher-discovered session below the excluded root is retained in
        // the scan model but never enters any upsert batch.
        let secondUUID = "bbbbcccc-1122-3344-5566-77889900aabb"
        let secondRel = "sessions/2026/08/14/rollout-\(secondUUID).jsonl"
        try TestSupport.write(
            [
                CodexScannerTests.meta(cwd: "/work/client/new", id: secondUUID),
                CodexScannerTests.userMessage("new excluded session"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(secondRel))
        let watcherRefresh = await relaunched.refresh(enabledAgents: both)
        #expect(!watcherRefresh.upserts.contains { $0.id == "codex:\(secondUUID)" })

        // Overlapping child removal cannot re-include records still covered by
        // the parent; removing the final parent re-donates only affected ids.
        #expect(try await relaunched.addProjectExclusion(path: "/work/client/app"))
        #expect(await relaunched.refresh(enabledAgents: both).isEmpty)
        #expect(try await relaunched.removeProjectExclusion(path: "/work/client/app"))
        #expect(await relaunched.refresh(enabledAgents: both).isEmpty)
        #expect(try await relaunched.removeProjectExclusion(path: "/work/client"))
        let restored = await relaunched.refresh(enabledAgents: both)
        #expect(Set(restored.upserts.map(\.id)) == [codexID, "codex:\(secondUUID)"])
        await relaunched.markIndexed(restored)
        #expect(await relaunched.refresh(enabledAgents: both).isEmpty)
    }

    @Test func exclusionFollowsWinningCwdAndPersistsWhenSourcesDisappear() async throws {
        let env = try makeEnv()
        try TestSupport.write(
            [
                CodexScannerTests.meta(cwd: "/work/client/app"),
                CodexScannerTests.userMessage("inside"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: [.codex])
        await store.markIndexed(initial)
        #expect(try await store.addProjectExclusion(path: "/work/client"))
        let hidden = await store.refresh(enabledAgents: [.codex])
        await store.markIndexed(hidden)

        // A resumed/forked session can have duplicate rollout paths. Once the
        // newest record for that id is outside the excluded tree it is targeted
        // for re-donation.
        let movedRel = "sessions/2026/08/14/rollout-moved-\(CodexScannerTests.uuid).jsonl"
        try TestSupport.write(
            [
                CodexScannerTests.meta(cwd: "/work/public"),
                CodexScannerTests.userMessage("moved outside"),
            ].joined(separator: "\n") + "\n",
            to: env.codexHome.appendingPathComponent(movedRel))
        let moved = await store.refresh(enabledAgents: [.codex])
        #expect(moved.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        await store.markIndexed(moved)

        // Removing the newer rollout reveals the still-excluded fallback and
        // therefore deletes the donated id again.
        try FileManager.default.removeItem(at: env.codexHome.appendingPathComponent(movedRel))
        let fallback = await store.refresh(enabledAgents: [.codex])
        #expect(fallback.deletedIDs == ["codex:\(CodexScannerTests.uuid)"])
        await store.markIndexed(fallback)

        // Missing transcripts do not erase an explicit directory policy.
        try FileManager.default.removeItem(
            at: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))
        _ = await store.refresh(enabledAgents: [.codex])
        #expect(await store.projectExclusionList().map(\.path) == ["/work/client"])
    }

    @Test func exclusionRemovalRequiresDurableRedonationBeforeClearingRule() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        let id = "codex:\(CodexScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: [.codex])
        await store.markIndexed(initial)
        #expect(try await store.addProjectExclusion(path: "/tmp/proj"))
        let excluded = await store.refresh(enabledAgents: [.codex])
        await store.markIndexed(excluded)

        // A directory at the cache file path makes the prerequisite atomic
        // cache write fail while the independent exclusion store is writable.
        try FileManager.default.removeItem(at: env.cacheURL)
        try FileManager.default.createDirectory(at: env.cacheURL, withIntermediateDirectories: false)
        var removalFailed = false
        do {
            _ = try await store.removeProjectExclusion(path: "/tmp/proj")
        } catch {
            removalFailed = true
        }
        #expect(removalFailed)
        #expect(await store.projectExclusionList().map(\.path) == ["/tmp/proj"])
        #expect(await store.record(id: id) == nil)
    }

    @Test func pinAndUnpinTargetOneUpsertThenStabilize() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)
        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)

        let id = "codex:\(CodexScannerTests.uuid)"
        #expect(try await store.setPinned(id: id, pinned: true) == .changed)
        let pinned = await store.refresh(enabledAgents: both)
        #expect(pinned.upserts.map(\.id) == [id])
        #expect(await store.titled(records: pinned.upserts).first?.isPinned == true)
        await store.markIndexed(pinned)
        #expect(try await store.setPinned(id: id, pinned: true) == .unchanged)
        #expect(await store.refresh(enabledAgents: both).isEmpty)

        #expect(try await store.setPinned(id: id, pinned: false) == .changed)
        let unpinned = await store.refresh(enabledAgents: both)
        #expect(unpinned.upserts.map(\.id) == [id])
        #expect(await store.titled(records: unpinned.upserts).first?.isPinned == false)
        await store.markIndexed(unpinned)
        #expect(await store.refresh(enabledAgents: both).isEmpty)
        #expect(try await store.setPinned(id: "codex:missing", pinned: true) == .unknownSession)
    }

    @Test func pinChangePersistsRedonationAcrossRelaunch() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)

        let id = "codex:\(CodexScannerTests.uuid)"
        #expect(try await store.setPinned(id: id, pinned: true) == .changed)

        // Model an exit after the pin update but before Spotlight acknowledges
        // the donation. Both the pin and its retry obligation must survive.
        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        let pending = await relaunched.refresh(enabledAgents: both)
        #expect(pending.upserts.map(\.id) == [id])
        #expect(await relaunched.titled(records: pending.upserts).first?.isPinned == true)
        await relaunched.markIndexed(pending)
        #expect(await relaunched.refresh(enabledAgents: both).isEmpty)
    }

    @Test func failedPinWritePreservesExistingDirtyObligation() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        let id = "codex:\(CodexScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)
        #expect(await store.markDirty(ids: [id]).isEmpty)

        try FileManager.default.removeItem(at: env.cacheURL)
        try FileManager.default.createDirectory(at: env.cacheURL, withIntermediateDirectories: false)
        var updateFailed = false
        do {
            _ = try await store.setPinned(id: id, pinned: true)
        } catch {
            updateFailed = true
        }
        #expect(updateFailed)

        try FileManager.default.removeItem(at: env.cacheURL)
        let retry = await store.refresh(enabledAgents: both)
        #expect(retry.upserts.map(\.id) == [id])
    }

    @Test func menuSectionsSortPinsAndDeduplicateRecents() async throws {
        let env = try makeEnv()
        try writeCodexSession(env, title: "Zulu")
        try writeClaudeSession(env, title: "alpha")
        let second = "bbbbcccc-1122-3344-5566-77889900aabb"
        try writeClaudeSession(env, uuid: second, title: "Beta")

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)
        try await store.setPinned(id: "codex:\(CodexScannerTests.uuid)", pinned: true)
        try await store.setPinned(id: "claude:\(ClaudeScannerTests.uuid)", pinned: true)

        let menu = await store.menuSections(recentLimit: 5)
        #expect(menu.pinned.map(\.title) == ["alpha", "Zulu"])
        #expect(menu.recent.map(\.record.id) == ["claude:\(second)"])
        #expect(Set(menu.pinned.map(\.record.id)).isDisjoint(with: menu.recent.map(\.record.id)))
    }

    @Test func pinsSurviveScanCacheResetAndAgentDisableThenPruneWithSource() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        try writeClaudeSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)
        let claudeID = "claude:\(ClaudeScannerTests.uuid)"
        #expect(try await store.setPinned(id: claudeID, pinned: true) == .changed)

        // Reset only the scan cache; the independent pin file must survive.
        try FileManager.default.removeItem(at: env.cacheURL)
        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        _ = await relaunched.refresh(enabledAgents: both)
        #expect(await relaunched.pinnedSessionIDs() == [claudeID])

        // A disabled agent cannot be verified: its pins are retained, so they
        // come back with their sessions when the agent is re-enabled.
        _ = await relaunched.refresh(enabledAgents: [.codex])
        #expect(await relaunched.pinnedSessionIDs() == [claudeID])
        let reenabled = await relaunched.refresh(enabledAgents: both)
        #expect(await relaunched.titled(records: reenabled.upserts).first { $0.record.id == claudeID }?.isPinned == true)

        // Only a complete scan that no longer sees the source prunes the pin.
        try FileManager.default.removeItem(
            at: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl"))
        _ = await relaunched.refresh(enabledAgents: both)
        #expect(await relaunched.pinnedSessionIDs().isEmpty)
    }

    @Test func cacheResetPlusTransientEnumerationFailurePreservesPins() async throws {
        let env = try makeEnv()
        try writeClaudeSession(env)
        let id = "claude:\(ClaudeScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)
        #expect(try await store.setPinned(id: id, pinned: true) == .changed)
        try FileManager.default.removeItem(at: env.cacheURL)

        let projectsRoot = env.claudeHome.appendingPathComponent("projects")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projectsRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectsRoot.path)
        }

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        _ = await relaunched.refresh(enabledAgents: both)
        #expect(await relaunched.pinnedSessionIDs() == [id])
    }

    @Test func corruptedPinStoreRedonatesStandardPriority() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        let id = "codex:\(CodexScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)
        #expect(try await store.setPinned(id: id, pinned: true) == .changed)
        let pinned = await store.refresh(enabledAgents: both)
        await store.markIndexed(pinned)

        let pinsURL = env.cacheURL.deletingLastPathComponent()
            .appendingPathComponent("pinned-sessions-v1.json")
        try TestSupport.write("not json", to: pinsURL)

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        let recovered = await relaunched.refresh(enabledAgents: both)
        #expect(recovered.upserts.map(\.id) == [id])
        #expect(await relaunched.titled(records: recovered.upserts).first?.isPinned == false)
    }

    @Test func pinnedSessionStaysVisibleOutsideHistoryWindow() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let id = "codex:\(CodexScannerTests.uuid)"
        try setActivity(
            now.addingTimeInterval(-40 * 86_400),
            at: env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel))

        let store = makeStore(env)
        await store.bootstrap()
        #expect(await store.refresh(enabledAgents: [.codex], historyWindow: .thirtyDays, now: now).isEmpty)

        #expect(try await store.setPinned(id: id, pinned: true) == .changed)
        let pinned = await store.refresh(enabledAgents: [.codex], historyWindow: .thirtyDays, now: now)
        #expect(pinned.upserts.map(\.id) == [id])
        await store.markIndexed(pinned)
        #expect(await store.record(id: id) != nil)
        #expect(await store.menuSections(recentLimit: 5).pinned.map(\.record.id) == [id])

        #expect(try await store.setPinned(id: id, pinned: false) == .changed)
        let unpinned = await store.refresh(enabledAgents: [.codex], historyWindow: .thirtyDays, now: now)
        #expect(unpinned.upserts.isEmpty)
        #expect(unpinned.deletedIDs == [id])
    }

    @Test func hidingBeatsPinningButKeepsThePin() async throws {
        let env = try makeEnv()
        try writeCodexSession(env)
        let id = "codex:\(CodexScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        await store.markIndexed(await store.refresh(enabledAgents: [.codex]))
        #expect(try await store.setPinned(id: id, pinned: true) == .changed)
        await store.markIndexed(await store.refresh(enabledAgents: [.codex]))

        #expect(try await store.hideSession(id: id))
        let hidden = await store.refresh(enabledAgents: [.codex])
        #expect(hidden.deletedIDs == [id])
        await store.markIndexed(hidden)
        #expect(await store.menuSections(recentLimit: 5).pinned.isEmpty)
        #expect(await store.pinnedSessionIDs() == [id])

        #expect(try await store.restoreSession(id: id))
        let restored = await store.refresh(enabledAgents: [.codex])
        #expect(restored.upserts.map(\.id) == [id])
        #expect(await store.titled(records: restored.upserts).first?.isPinned == true)
    }

    @Test func aliasPrecedenceAndUpstreamTitleRemainsSearchable() async throws {
        let env = try makeEnv()
        try writeCodexSession(env, title: "Agent title")
        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)
        let id = "codex:\(CodexScannerTests.uuid)"

        #expect(try await store.setAlias(id: id, alias: "  Local   alias ") == .changed)
        let changed = await store.refresh(enabledAgents: both)
        #expect(changed.upserts.map(\.id) == [id])
        let titled = try #require(await store.titled(records: changed.upserts).first)
        #expect(titled.title == "Local alias")
        #expect(titled.sourceTitle == "Agent title")
        await store.markIndexed(changed)

        // A duplicate request is stable, and entity string matching still
        // finds the session through its original agent title.
        #expect(try await store.setAlias(id: id, alias: "Local alias") == .unchanged)
        #expect(await store.refresh(enabledAgents: both).isEmpty)
        #expect(await store.allTitled(matching: "Agent title").map(\.record.id) == [id])

        try writeCodexSession(env, title: "Updated agent title")
        let upstreamChanged = await store.refresh(enabledAgents: both)
        let updated = try #require(await store.titled(records: upstreamChanged.upserts).first)
        #expect(updated.title == "Local alias")
        #expect(updated.sourceTitle == "Updated agent title")
    }

    @Test func clearingAliasTargetsOneUpsertAndUnknownFails() async throws {
        let env = try makeEnv()
        try writeClaudeSession(env, title: "Claude source")
        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)
        let id = "claude:\(ClaudeScannerTests.uuid)"

        _ = try await store.setAlias(id: id, alias: "Claude alias")
        let aliased = await store.refresh(enabledAgents: both)
        await store.markIndexed(aliased)
        #expect(try await store.clearAlias(id: id) == .changed)
        let cleared = await store.refresh(enabledAgents: both)
        #expect(cleared.upserts.map(\.id) == [id])
        #expect(await store.titled(records: cleared.upserts).first?.title == "Claude source")
        await store.markIndexed(cleared)
        #expect(try await store.clearAlias(id: id) == .unchanged)
        #expect(await store.refresh(enabledAgents: both).isEmpty)
        #expect(try await store.setAlias(id: "codex:missing", alias: "No") == .unknownSession)
    }

    @Test func aliasChangesRequireDurableRedonationBeforeStateWrite() async throws {
        let setEnv = try makeEnv()
        try writeCodexSession(setEnv)
        let codexID = "codex:\(CodexScannerTests.uuid)"
        let setStore = makeStore(setEnv)
        await setStore.bootstrap()
        let setInitial = await setStore.refresh(enabledAgents: both)
        await setStore.markIndexed(setInitial)

        try FileManager.default.removeItem(at: setEnv.cacheURL)
        try FileManager.default.createDirectory(
            at: setEnv.cacheURL, withIntermediateDirectories: false)
        var setFailed = false
        do {
            _ = try await setStore.setAlias(id: codexID, alias: "Must not persist")
        } catch {
            setFailed = true
        }
        #expect(setFailed)
        #expect(await setStore.aliases().isEmpty)

        let clearEnv = try makeEnv()
        try writeClaudeSession(clearEnv)
        let claudeID = "claude:\(ClaudeScannerTests.uuid)"
        let clearStore = makeStore(clearEnv)
        await clearStore.bootstrap()
        let clearInitial = await clearStore.refresh(enabledAgents: both)
        await clearStore.markIndexed(clearInitial)
        #expect(try await clearStore.setAlias(id: claudeID, alias: "Keep on failure") == .changed)

        try FileManager.default.removeItem(at: clearEnv.cacheURL)
        try FileManager.default.createDirectory(
            at: clearEnv.cacheURL, withIntermediateDirectories: false)
        var clearFailed = false
        do {
            _ = try await clearStore.clearAlias(id: claudeID)
        } catch {
            clearFailed = true
        }
        #expect(clearFailed)
        #expect(await clearStore.aliases() == [claudeID: "Keep on failure"])
    }

    @Test func aliasesSurviveScanCacheResetAndPruneWithDeletedSession() async throws {
        let env = try makeEnv()
        try writeClaudeSession(env)
        let id = "claude:\(ClaudeScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)
        _ = try await store.setAlias(id: id, alias: "Persistent alias")

        // Reset only the scan cache; aliases are a separate user-owned file.
        try FileManager.default.removeItem(at: env.cacheURL)
        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        _ = await relaunched.refresh(enabledAgents: both)
        #expect(await relaunched.aliases() == [id: "Persistent alias"])

        try FileManager.default.removeItem(
            at: env.claudeHome.appendingPathComponent("projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl"))
        _ = await relaunched.refresh(enabledAgents: both)
        #expect(await relaunched.aliases().isEmpty)

        let afterDelete = makeStore(env)
        await afterDelete.bootstrap()
        #expect(await afterDelete.aliases().isEmpty)
    }

    @Test func aliasesSurviveAgentDisableAndReturnWhenReenabled() async throws {
        let env = try makeEnv()
        try writeClaudeSession(env, title: "Agent title")
        let id = "claude:\(ClaudeScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)
        #expect(try await store.setAlias(id: id, alias: "Persistent alias") == .changed)
        let aliased = await store.refresh(enabledAgents: both)
        await store.markIndexed(aliased)

        let disabled = await store.refresh(enabledAgents: [.codex])
        #expect(disabled.deletedIDs == [id])
        #expect(await store.aliases() == [id: "Persistent alias"])
        await store.markIndexed(disabled)

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        _ = await relaunched.refresh(enabledAgents: [.codex])
        #expect(await relaunched.aliases() == [id: "Persistent alias"])

        let restored = await relaunched.refresh(enabledAgents: both)
        #expect(restored.upserts.map(\.id) == [id])
        #expect(await relaunched.titled(records: restored.upserts).first?.title == "Persistent alias")
    }

    @Test func cacheResetPlusTransientEnumerationFailurePreservesAliases() async throws {
        let env = try makeEnv()
        try writeClaudeSession(env)
        let id = "claude:\(ClaudeScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)
        _ = try await store.setAlias(id: id, alias: "Do not erase")
        try FileManager.default.removeItem(at: env.cacheURL)

        let projectsRoot = env.claudeHome.appendingPathComponent("projects")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projectsRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectsRoot.path)
        }

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        _ = await relaunched.refresh(enabledAgents: both)
        #expect(await relaunched.aliases() == [id: "Do not erase"])
    }

    @Test func cacheResetPlusUnusableTranscriptPreservesAliases() async throws {
        let env = try makeEnv()
        try writeClaudeSession(env, title: "Agent title")
        let id = "claude:\(ClaudeScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        _ = await store.refresh(enabledAgents: both)
        #expect(try await store.setAlias(id: id, alias: "Do not erase") == .changed)
        try FileManager.default.removeItem(at: env.cacheURL)
        try TestSupport.write(
            "temporarily unusable transcript\n",
            to: env.claudeHome.appendingPathComponent(
                "projects/-tmp-proj/\(ClaudeScannerTests.uuid).jsonl"))

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        _ = await relaunched.refresh(enabledAgents: both)
        #expect(await relaunched.aliases() == [id: "Do not erase"])

        try writeClaudeSession(env, title: "Recovered title")
        let recovered = await relaunched.refresh(enabledAgents: both)
        #expect(recovered.upserts.map(\.id) == [id])
        #expect(await relaunched.titled(records: recovered.upserts).first?.title == "Do not erase")
    }

    @Test func corruptedAliasStoreRedonatesSourceTitle() async throws {
        let env = try makeEnv()
        try writeCodexSession(env, title: "Agent title")
        let id = "codex:\(CodexScannerTests.uuid)"

        let store = makeStore(env)
        await store.bootstrap()
        let initial = await store.refresh(enabledAgents: both)
        await store.markIndexed(initial)
        #expect(try await store.setAlias(id: id, alias: "Local alias") == .changed)
        let aliased = await store.refresh(enabledAgents: both)
        await store.markIndexed(aliased)

        let aliasesURL = env.cacheURL.deletingLastPathComponent()
            .appendingPathComponent("session-aliases-v1.json")
        try TestSupport.write("not json", to: aliasesURL)

        let relaunched = makeStore(env)
        await relaunched.bootstrap()
        #expect(await relaunched.warnings().contains { $0.contains("aliases") })
        let recovered = await relaunched.refresh(enabledAgents: both)
        #expect(recovered.upserts.map(\.id) == [id])
        #expect(await relaunched.titled(records: recovered.upserts).first?.title == "Agent title")
        #expect(await relaunched.warnings().contains { $0.contains("aliases") })
    }
}
