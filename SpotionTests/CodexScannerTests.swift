import Foundation
import Testing

@Suite struct CodexScannerTests {
    static let uuid = "019fd165-b969-7562-bd4e-0fa4a6104c38"
    static let sessionRel = "sessions/2026/08/05/rollout-2026-08-05T18-08-52-\(uuid).jsonl"

    static func meta(cwd: String = "/tmp/proj", id: String? = uuid, extra: String = "") -> String {
        let idPart = id.map { "\"session_id\":\"\($0)\",\"id\":\"\($0)\"," } ?? ""
        return "{\"timestamp\":\"2026-08-05T10:08:52.613Z\",\"type\":\"session_meta\",\"payload\":{\(idPart)\"timestamp\":\"2026-08-05T10:08:52.613Z\",\"cwd\":\"\(cwd)\"\(extra)}}"
    }

    static let taskStarted =
        "{\"timestamp\":\"2026-08-05T10:08:53.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"t1\"}}"

    static func userMessage(_ text: String) -> String {
        "{\"timestamp\":\"2026-08-05T10:08:54.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(text)\"}}"
    }

    static let responseItemUser =
        "{\"timestamp\":\"2026-08-05T10:08:55.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"CONTEXT INJECTION\"}]}}"

    private func makeHome(sessionLines: [String], rel: String = sessionRel) throws -> URL {
        let home = try TestSupport.makeTempDir()
        try TestSupport.write(sessionLines.joined(separator: "\n") + "\n", to: home.appendingPathComponent(rel))
        return home
    }

    private func firstRecord(home: URL) throws -> SessionRecord {
        let scanner = CodexScanner(codexHome: home)
        let files = try #require(scanner.enumerateFiles())
        try #require(files.count == 1)
        let record = scanner.parse(files[0])
        return try #require(record)
    }

    @Test func parsesMetaAndFirstUserMessage() throws {
        let home = try makeHome(sessionLines: [Self.meta(), Self.taskStarted, Self.userMessage("修复登录 bug")])
        let record = try firstRecord(home: home)
        #expect(record.id == "codex:\(Self.uuid)")
        #expect(record.sessionID == Self.uuid)
        #expect(record.cwd == "/tmp/proj")
        #expect(record.projectName == "proj")
        #expect(record.firstPrompt == "修复登录 bug")
        #expect(record.startedAt != nil)
    }

    @Test func promptBeyondFirstWindowIsFoundByExpansion() throws {
        // meta 在首个 512KB 窗口内、巨型 response_item 把首条 user_message 推出窗口：
        // 扩窗必须继续，直到找到 prompt（而不是拿着 firstPrompt==nil 提前返回）
        let hugeInjection = String(repeating: "B", count: 600_000)
        let giantResponseItem =
            "{\"timestamp\":\"t\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"\(hugeInjection)\"}]}}"
        let home = try makeHome(sessionLines: [Self.meta(), giantResponseItem, Self.userMessage("深处的提示")])
        let record = try firstRecord(home: home)
        #expect(record.firstPrompt == "深处的提示")
    }

    @Test func hugeMetaLineStillParses() throws {
        let padding = String(repeating: "A", count: 100_000)
        let home = try makeHome(sessionLines: [
            Self.meta(extra: ",\"base_instructions\":{\"text\":\"\(padding)\"}"),
            Self.userMessage("hello after huge meta"),
        ])
        let record = try firstRecord(home: home)
        #expect(record.firstPrompt == "hello after huge meta")
    }

    @Test func metaBeyondInitialWindowTriggersExpansion() throws {
        // meta 行 ~600KB，超出 512KB 初始窗口 → 扩窗后仍能解析
        let padding = String(repeating: "B", count: 600_000)
        let home = try makeHome(sessionLines: [
            Self.meta(extra: ",\"base_instructions\":{\"text\":\"\(padding)\"}"),
            Self.userMessage("after expansion"),
        ])
        let record = try firstRecord(home: home)
        #expect(record.cwd == "/tmp/proj")
        #expect(record.firstPrompt == "after expansion")
    }

    @Test func ignoresResponseItemUserRecords() throws {
        let home = try makeHome(sessionLines: [Self.meta(), Self.responseItemUser])
        let record = try firstRecord(home: home)
        #expect(record.firstPrompt == nil)
    }

    @Test func malformedLinesAreSkipped() throws {
        let home = try makeHome(sessionLines: [Self.meta(), "THIS IS NOT JSON", Self.userMessage("still works")])
        let record = try firstRecord(home: home)
        #expect(record.firstPrompt == "still works")
    }

    @Test func uuidFallbackFromFilename() throws {
        let home = try makeHome(sessionLines: [Self.meta(id: nil), Self.userMessage("x")])
        let record = try firstRecord(home: home)
        #expect(record.sessionID == Self.uuid)
    }

    @Test func enumerationFiltersNonRolloutFiles() throws {
        let home = try makeHome(sessionLines: [Self.meta()])
        try TestSupport.write("x", to: home.appendingPathComponent("sessions/2026/08/05/notes.txt"))
        try TestSupport.write("{}", to: home.appendingPathComponent("sessions/2026/08/05/other.jsonl"))
        let scanner = CodexScanner(codexHome: home)
        #expect(scanner.enumerateFiles()?.count == 1)
    }

    @Test func missingRootIsLegitimatelyEmpty() throws {
        let home = try TestSupport.makeTempDir()  // 无 sessions 子目录
        let scanner = CodexScanner(codexHome: home)
        #expect(scanner.enumerateFiles()?.isEmpty == true)
    }

    @Test func titleIndexLaterLineWins() throws {
        let home = try TestSupport.makeTempDir()
        let index = """
        {"id":"\(Self.uuid)","thread_name":"旧名字","updated_at":"2026-08-01T00:00:00Z"}
        {"id":"\(Self.uuid)","thread_name":"新名字","updated_at":"2026-08-05T00:00:00Z"}
        """
        try TestSupport.write(index + "\n", to: home.appendingPathComponent("session_index.jsonl"))
        let titles = try #require(CodexScanner(codexHome: home).loadTitleIndex())
        #expect(titles[Self.uuid] == "新名字")
    }

    @Test func titleIndexDistinguishesMissingFromUnreadable() throws {
        let home = try TestSupport.makeTempDir()
        // 文件不存在：合法的空（标题被清除的语义）
        #expect(CodexScanner(codexHome: home).loadTitleIndex()?.isEmpty == true)

        // 文件存在但不可读：nil（I/O 失败，调用方须保留旧标题）
        let indexURL = home.appendingPathComponent("session_index.jsonl")
        try TestSupport.write("{\"id\":\"x\",\"thread_name\":\"y\"}\n", to: indexURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: indexURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexURL.path)
        }
        #expect(CodexScanner(codexHome: home).loadTitleIndex() == nil)
    }
}
