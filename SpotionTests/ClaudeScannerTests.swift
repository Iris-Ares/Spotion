import Foundation
import Testing

@Suite struct ClaudeScannerTests {
    static let uuid = "aabbccdd-1122-3344-5566-77889900aabb"

    static let queueOp =
        "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"timestamp\":\"2026-08-05T10:00:00.000Z\",\"sessionId\":\"\(uuid)\"}"

    static func user(_ content: String, sidechain: Bool = false, cwd: String = "/tmp/proj") -> String {
        "{\"type\":\"user\",\"sessionId\":\"\(uuid)\",\"cwd\":\"\(cwd)\",\"gitBranch\":\"main\",\"timestamp\":\"2026-08-05T10:00:01.000Z\",\"isSidechain\":\(sidechain),\"message\":{\"role\":\"user\",\"content\":\"\(content)\"}}"
    }

    static let userWithBlocks =
        "{\"type\":\"user\",\"sessionId\":\"\(uuid)\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"2026-08-05T10:00:01.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"块一\"},{\"type\":\"tool_result\",\"text\":\"忽略我\"}]}}"

    static func assistantFiller(_ length: Int) -> String {
        let text = String(repeating: "F", count: length)
        return "{\"type\":\"assistant\",\"sessionId\":\"\(uuid)\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"2026-08-05T10:00:02.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"content\":\"\(text)\"}}"
    }

    static func customTitle(_ t: String) -> String {
        "{\"type\":\"custom-title\",\"customTitle\":\"\(t)\",\"sessionId\":\"\(uuid)\"}"
    }
    static func aiTitle(_ t: String) -> String {
        "{\"type\":\"ai-title\",\"aiTitle\":\"\(t)\",\"sessionId\":\"\(uuid)\"}"
    }
    static func lastPrompt(_ t: String) -> String {
        "{\"type\":\"last-prompt\",\"lastPrompt\":\"\(t)\",\"leafUuid\":\"x\",\"sessionId\":\"\(uuid)\"}"
    }

    private func makeHome(lines: [String]) throws -> URL {
        let home = try TestSupport.makeTempDir()
        try TestSupport.write(
            lines.joined(separator: "\n") + "\n",
            to: home.appendingPathComponent("projects/-tmp-proj/\(Self.uuid).jsonl"))
        return home
    }

    private func firstRecord(home: URL) throws -> SessionRecord {
        let scanner = ClaudeScanner(claudeHome: home)
        let files = try #require(scanner.enumerateFiles())
        try #require(files.count == 1)
        return try #require(scanner.parse(files[0]))
    }

    @Test func queueOperationFirstLineThenEnvelope() throws {
        let home = try makeHome(lines: [Self.queueOp, Self.user("帮我写个脚本")])
        let record = try firstRecord(home: home)
        #expect(record.id == "claude:\(Self.uuid)")
        #expect(record.sessionID == Self.uuid)
        #expect(record.cwd == "/tmp/proj")
        #expect(record.gitBranch == "main")
        #expect(record.firstPrompt == "帮我写个脚本")
    }

    @Test func skipsSidechainCommandAndCaveatPrompts() throws {
        let home = try makeHome(lines: [
            Self.user("子 agent 消息", sidechain: true),
            Self.user("<command-name>/clear</command-name>"),
            Self.user("Caveat: The messages below were generated…"),
            Self.user("真正的问题"),
        ])
        let record = try firstRecord(home: home)
        #expect(record.firstPrompt == "真正的问题")
    }

    @Test func blockContentConcatenatesTextBlocksOnly() throws {
        let home = try makeHome(lines: [Self.userWithBlocks])
        let record = try firstRecord(home: home)
        #expect(record.firstPrompt == "块一")
    }

    @Test func titlePriorityCustomOverAIOverLastPrompt() throws {
        let home = try makeHome(lines: [
            Self.user("prompt"),
            Self.aiTitle("AI 标题"),
            Self.customTitle("自定义标题"),
            Self.lastPrompt("最后的提示"),
        ])
        let record = try firstRecord(home: home)
        #expect(record.fallbackTitle == "自定义标题")
    }

    @Test func titleLastOccurrenceWins() throws {
        let home = try makeHome(lines: [
            Self.user("prompt"),
            Self.customTitle("旧标题"),
            Self.customTitle("新标题"),
        ])
        let record = try firstRecord(home: home)
        #expect(record.fallbackTitle == "新标题")
    }

    @Test func aiTitleUsedWhenNoCustom() throws {
        let home = try makeHome(lines: [Self.user("prompt"), Self.aiTitle("AI 标题"), Self.lastPrompt("尾提示")])
        let record = try firstRecord(home: home)
        #expect(record.fallbackTitle == "AI 标题")
    }

    @Test func tailExpansionFindsTitlesBeyondFirstWindow() throws {
        // 标题记录在文件前部，其后 ~100KB 填充 → 64KB tail 窗口找不到，扩窗后命中
        var lines = [Self.user("prompt"), Self.customTitle("藏得深的标题")]
        for _ in 0..<50 { lines.append(Self.assistantFiller(2000)) }
        let home = try makeHome(lines: lines)
        let record = try firstRecord(home: home)
        #expect(record.fallbackTitle == "藏得深的标题")
    }

    @Test func headExpansionHandlesHugeFirstEnvelopeLine() throws {
        // 首条含 cwd 的 user 记录是一条 ~300KB 的巨型行（粘贴内容），
        // 且前面只有无 envelope 的 queue-operation → 需扩窗才能解析
        let huge = String(repeating: "内容", count: 100_000)  // ~600KB UTF-8
        let home = try makeHome(lines: [Self.queueOp, Self.user(huge), Self.customTitle("扩窗标题")])
        let record = try firstRecord(home: home)
        #expect(record.cwd == "/tmp/proj")
        #expect(record.fallbackTitle == "扩窗标题")
    }

    @Test func noCwdReturnsNil() throws {
        let home = try makeHome(lines: [Self.queueOp])
        let scanner = ClaudeScanner(claudeHome: home)
        let files = try #require(scanner.enumerateFiles())
        try #require(files.count == 1)
        #expect(scanner.parse(files[0]) == nil)
    }

    @Test func subagentTranscriptsExcluded() throws {
        let home = try makeHome(lines: [Self.user("main")])
        try TestSupport.write(
            Self.user("sub"),
            to: home.appendingPathComponent("projects/-tmp-proj/\(Self.uuid)/subagents/agent-1.jsonl"))
        let scanner = ClaudeScanner(claudeHome: home)
        #expect(scanner.enumerateFiles()?.count == 1)
    }
}
