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

    static func userMessageWithAttachment(_ text: String) -> String {
        "{\"timestamp\":\"2026-08-05T10:08:54.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(text)\",\"images\":[\"SECRET_ATTACHMENT_PAYLOAD\"]}}"
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
        return try #require(scanner.parse(files[0]).record)
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
        #expect(record.laterPromptSnippets.isEmpty)
    }

    @Test func optInExtractsOnlyRecentRealUserPrompts() throws {
        let assistant =
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"SECRET_ASSISTANT\"}]}}"
        let thinking =
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"summary\":[{\"text\":\"SECRET_THINKING\"}]}}"
        let tool =
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"SECRET_TOOL\"}}"
        let home = try makeHome(sessionLines: [
            Self.meta(),
            Self.userMessage("first prompt"),
            Self.responseItemUser,
            assistant,
            thinking,
            tool,
            Self.userMessage("<command-name>/review</command-name>"),
            Self.userMessage("  later   prompt   one  "),
            Self.userMessageWithAttachment("later prompt two"),
            "MALFORMED TAIL LINE",
        ])
        let scanner = CodexScanner(codexHome: home)
        let file = try #require(scanner.enumerateFiles()?.first)
        let record = try #require(scanner.parse(file, includeLaterPrompts: true).record)

        #expect(record.laterPromptSnippets == ["later prompt two", "later prompt one"])
        let donated = record.laterPromptSnippets.joined(separator: "\n")
        #expect(!donated.contains("SECRET_"))
        #expect(!donated.contains("command-name"))
    }

    @Test func laterPromptLimitsDuplicatesAndOversizedBoundaryRecords() throws {
        let giant = String(repeating: "Z", count: PromptSnippetPolicy.tailReadCap + 1_024)
        let home = try makeHome(sessionLines: [
            Self.meta(),
            Self.userMessage("first prompt"),
            Self.userMessage(giant),
            "NOT JSON",
            Self.userMessage("duplicate"),
            Self.userMessage("duplicate"),
            Self.userMessage(String(repeating: "A", count: 400)),
            Self.userMessage(String(repeating: "B", count: 400)),
            Self.userMessage(String(repeating: "C", count: 400)),
            Self.userMessage(String(repeating: "D", count: 400)),
            Self.userMessage(String(repeating: "E", count: 400)),
            Self.userMessage("newest"),
        ])
        let scanner = CodexScanner(codexHome: home)
        let file = try #require(scanner.enumerateFiles()?.first)
        let record = try #require(scanner.parse(file, includeLaterPrompts: true).record)

        #expect(record.laterPromptSnippets.count == 5)
        #expect(record.laterPromptSnippets.first == "newest")
        #expect(record.laterPromptSnippets.allSatisfy { $0.count <= 300 })
        #expect(record.laterPromptSnippets.joined(separator: "\n").count <= 1_500)
        #expect(!record.laterPromptSnippets.contains("duplicate"))
    }

    @Test func disabledContentDescriptionExcludesCachedLaterPrompts() throws {
        let home = try makeHome(sessionLines: [Self.meta(), Self.userMessage("first")])
        var record = try firstRecord(home: home)
        record.laterPromptSnippets = ["distinctive later phrase"]

        let disabled = record.spotlightContentDescription(includeLaterPrompts: false)
        let enabled = record.spotlightContentDescription(includeLaterPrompts: true)
        #expect(!disabled.contains("distinctive later phrase"))
        #expect(enabled.contains("distinctive later phrase"))
    }

    @Test func promptBeyondFirstWindowIsFoundByExpansion() throws {
        // meta fits the initial 512KB window, but a giant response_item pushes
        // the first user_message past it: expansion must continue until the
        // prompt is found (not return early with firstPrompt == nil)
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
        // A ~600KB meta line exceeds the 512KB initial window → still parses
        // after expansion
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
        let home = try TestSupport.makeTempDir()  // no sessions subdirectory
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
        // File missing: legitimately empty (titles-were-cleared semantics)
        #expect(CodexScanner(codexHome: home).loadTitleIndex()?.isEmpty == true)

        // File exists but is unreadable: nil (I/O failure — the caller must
        // keep its cached titles)
        let indexURL = home.appendingPathComponent("session_index.jsonl")
        try TestSupport.write("{\"id\":\"x\",\"thread_name\":\"y\"}\n", to: indexURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: indexURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexURL.path)
        }
        #expect(CodexScanner(codexHome: home).loadTitleIndex() == nil)
    }
}
