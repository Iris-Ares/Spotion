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
        // 标题条目从 session_index.jsonl 消失 → 该会话必须重灌（否则 Spotlight 挂旧标题）
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
        #expect(await store.displayTitle(for: record) == "codex prompt")  // 回退到首 prompt
    }

    @Test func markDirtyForcesUpsertAndReportsUnknown() async throws {
        // 系统点名重灌：已知 id 强制产生 upsert（即使文件未变），未知 id 原样返回
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
        // 根目录被成功枚举但已无任何会话文件（[] 而非 nil）→ 最后一个会话必须从索引删除
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
        // 根目录不可读（枚举失败 nil）→ 保护性保留，不产生删除
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
        // 已索引会话内容变更 → donate 失败（不调 markIndexed）→ 下轮 refresh 仍须重报该 id
        let env = try makeEnv()
        try writeCodexSession(env)

        let store = makeStore(env)
        await store.bootstrap()
        let d1 = await store.refresh(enabledAgents: both)
        await store.markIndexed(d1)

        // 内容追加（mtime+size 变化）
        let path = env.codexHome.appendingPathComponent(CodexScannerTests.sessionRel)
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((CodexScannerTests.userMessage("更新") + "\n").utf8))
        try handle.close()

        let d2 = await store.refresh(enabledAgents: both)
        #expect(d2.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        // 模拟 donate 失败：不调用 markIndexed

        let d3 = await store.refresh(enabledAgents: both)
        #expect(d3.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        await store.markIndexed(d3)

        let d4 = await store.refresh(enabledAgents: both)
        #expect(d4.isEmpty)
    }

    @Test func duplicateSessionIDNewestFileWins() async throws {
        // codex resume/fork 会为同一 session_id 生成多个 rollout 文件：新 mtime 者胜；
        // 新文件删除后回退到旧文件而不是丢失会话
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
        // 路径断言用后缀比较：/var 与 /private/var 是同一位置的符号链接两侧
        var record = try #require(await store.record(id: "codex:\(CodexScannerTests.uuid)"))
        #expect(record.filePath.hasSuffix(newRel))
        await store.markIndexed(d1)

        try FileManager.default.removeItem(at: newURL)
        let d2 = await store.refresh(enabledAgents: [.codex])
        #expect(d2.deletedIDs.isEmpty)
        // 胜者文件被删 → 回退文件必须重新 donate（修正 Spotlight 上的元数据）
        #expect(d2.upserts.map(\.id) == ["codex:\(CodexScannerTests.uuid)"])
        record = try #require(await store.record(id: "codex:\(CodexScannerTests.uuid)"))
        #expect(record.filePath.hasSuffix(oldRel))
        await store.markIndexed(d2)
        let d3 = await store.refresh(enabledAgents: [.codex])
        #expect(d3.isEmpty)
    }

    @Test func staleCacheFileTriggersFullRebuild() async throws {
        // 缓存文件存在但版本过旧/损坏 → 旧 indexedIDs 已丢，必须请求 deleteAll+全量重灌
        let env = try makeEnv()
        try TestSupport.write(
            "{\"version\":1,\"entries\":{},\"indexedIDs\":[\"codex:stale\"],\"codexTitles\":{}}",
            to: env.cacheURL)
        let store = makeStore(env)
        await store.bootstrap()
        #expect(await store.consumePendingFullRebuild() == true)
        #expect(await store.consumePendingFullRebuild() == false)  // 只消费一次

        // 全新环境（无缓存文件）不应触发重建
        let freshEnv = try makeEnv()
        let freshStore = makeStore(freshEnv)
        await freshStore.bootstrap()
        #expect(await freshStore.consumePendingFullRebuild() == false)

        // 损坏（非 JSON）同样触发
        let corruptEnv = try makeEnv()
        try TestSupport.write("NOT JSON AT ALL", to: corruptEnv.cacheURL)
        let corruptStore = makeStore(corruptEnv)
        await corruptStore.bootstrap()
        #expect(await corruptStore.consumePendingFullRebuild() == true)
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
