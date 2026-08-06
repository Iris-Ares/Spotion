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
        // Title records sit near the head with ~100KB of filler after them →
        // the 64KB tail window misses them, expansion finds them
        var lines = [Self.user("prompt"), Self.customTitle("藏得深的标题")]
        for _ in 0..<50 { lines.append(Self.assistantFiller(2000)) }
        let home = try makeHome(lines: lines)
        let record = try firstRecord(home: home)
        #expect(record.fallbackTitle == "藏得深的标题")
    }

    @Test func headExpansionHandlesHugeFirstEnvelopeLine() throws {
        // The first cwd-bearing user record is a giant pasted-content line,
        // preceded only by an envelope-less queue-operation → parsing requires
        // head-window expansion
        let huge = String(repeating: "内容", count: 100_000)  // ~600KB of UTF-8
        let home = try makeHome(lines: [Self.queueOp, Self.user(huge), Self.customTitle("扩窗标题")])
        let record = try firstRecord(home: home)
        #expect(record.cwd == "/tmp/proj")
        #expect(record.fallbackTitle == "扩窗标题")
    }

    @Test func tailExpansionPrefersHigherPriorityTitleDeeperInFile() throws {
        // custom-title near the head, last-prompt at the very end: the 64KB
        // window sees only the last-prompt, expansion must continue, and the
        // custom-title wins in the end
        var lines = [Self.user("prompt"), Self.customTitle("更高优先级的标题")]
        for _ in 0..<50 { lines.append(Self.assistantFiller(2000)) }
        lines.append(Self.lastPrompt("尾部的低优先级提示"))
        let home = try makeHome(lines: lines)
        let record = try firstRecord(home: home)
        #expect(record.fallbackTitle == "更高优先级的标题")
    }

    @Test func promptBeyondFirstWindowIsFoundByExpansion() throws {
        // An early envelope supplies cwd (a filtered command wrapper), then a
        // giant assistant record pushes the first real prompt past the 256KB
        // initial window: expansion must continue until the prompt is found
        // instead of returning early with firstPrompt == nil
        let home = try makeHome(lines: [
            Self.user("<command-name>/clear</command-name>"),
            Self.assistantFiller(300_000),
            Self.user("prompt beyond the window"),
            Self.customTitle("tail title"),
        ])
        let record = try firstRecord(home: home)
        #expect(record.firstPrompt == "prompt beyond the window")
        #expect(record.fallbackTitle == "tail title")
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
