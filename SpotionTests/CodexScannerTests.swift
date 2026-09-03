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

    static func assistantMessage(
        _ texts: [String],
        blockType: String = "output_text",
        phase: String? = "final_answer"
    ) throws -> String {
        var payload: [String: Any] = [
            "type": "message",
            "role": "assistant",
            "content": texts.map { ["type": blockType, "text": $0] },
        ]
        if let phase { payload["phase"] = phase }
        return String(decoding: try JSONSerialization.data(
            withJSONObject: ["type": "response_item", "payload": payload]), as: UTF8.self)
    }

    static func fileToolCall(
        _ name: String,
        field: String = "path",
        path: String,
        namespace: String? = nil
    ) throws -> String {
        let arguments = try JSONSerialization.data(withJSONObject: [field: path], options: [.sortedKeys])
        var payload: [String: Any] = [
            "type": "function_call",
            "name": name,
            "arguments": String(decoding: arguments, as: UTF8.self),
        ]
        if let namespace { payload["namespace"] = namespace }
        let line: [String: Any] = ["type": "response_item", "payload": payload]
        return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }

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

    @Test func assistantReplyOptInAllowsOnlyVisibleMessageText() throws {
        let reasoning =
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"summary\":[{\"text\":\"SECRET_REASONING\"}]}}"
        let toolOutput =
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"SECRET_TOOL_OUTPUT\"}}"
        let eventMessage =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"SECRET_EVENT\"}}"
        let home = try makeHome(sessionLines: [
            Self.meta(),
            Self.userMessage("first prompt"),
            try Self.assistantMessage(["  older   visible reply  "]),
            reasoning,
            toolOutput,
            eventMessage,
            Self.responseItemUser,
            try Self.assistantMessage(["SECRET_COMMENTARY"], phase: "commentary"),
            try Self.assistantMessage(["SECRET_UNKNOWN_BLOCK"], blockType: "future_text"),
            try Self.assistantMessage(["new visible", "reply part"]),
            "MALFORMED TAIL LINE",
        ])
        let scanner = CodexScanner(codexHome: home)
        let file = try #require(scanner.enumerateFiles()?.first)

        let disabled = try #require(scanner.parse(file).record)
        #expect(disabled.assistantReplySnippets.isEmpty)

        let enabled = try #require(scanner.parse(
            file,
            includeLaterPrompts: false,
            includeTouchedFiles: false,
            includeAssistantReplies: true
        ).record)
        #expect(enabled.assistantReplySnippets == ["new visible reply part", "older visible reply"])
        #expect(enabled.assistantReplyHydrationGeneration == AssistantReplySnippetPolicy.extractionGeneration)
        #expect(!enabled.assistantReplySnippets.joined(separator: " ").contains("SECRET_"))
    }

    @Test func assistantReplyLimitsDuplicatesAndBoundedTail() throws {
        let giant = String(repeating: "Z", count: AssistantReplySnippetPolicy.tailReadCap + 1_024)
        var lines = [Self.meta(), Self.userMessage("first"), try Self.assistantMessage(["outside bounded tail"])]
        lines.append(try Self.assistantMessage([giant]))
        lines.append(contentsOf: try ["duplicate", "duplicate", "A", "B", "C", "D", "newest"].map {
            try Self.assistantMessage([String(repeating: $0, count: 400)])
        })
        let home = try makeHome(sessionLines: lines)
        let scanner = CodexScanner(codexHome: home)
        let file = try #require(scanner.enumerateFiles()?.first)
        let record = try #require(scanner.parse(
            file,
            includeLaterPrompts: false,
            includeTouchedFiles: false,
            includeAssistantReplies: true
        ).record)

        #expect(record.assistantReplySnippets.count == 5)
        #expect(record.assistantReplySnippets.first == String(repeating: "newest", count: 50))
        #expect(record.assistantReplySnippets.allSatisfy { $0.count <= 300 })
        #expect(record.assistantReplySnippets.joined(separator: "\n").count <= 1_500)
        #expect(!record.assistantReplySnippets.contains("outside bounded tail"))
    }

    @Test func touchedFilesUseOnlyAllowlistedStructuredInputs() throws {
        let shell = "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"cat Sources/ShellSecret.swift\\\"}\"}}"
        let patch = "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"name\":\"apply_patch\",\"input\":\"*** Update File: Sources/PatchSecret.swift\"}}"
        let output = "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"Sources/OutputSecret.swift\"}}"
        let assistant = "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Sources/ProseSecret.swift\"}]}}"
        let home = try makeHome(sessionLines: [
            Self.meta(cwd: "/tmp/proj"),
            Self.userMessage("please inspect Sources/UserPromptSecret.swift"),
            try Self.fileToolCall("read_file", path: "/tmp/proj/Sources/Auth Service.swift"),
            try Self.fileToolCall("write_file", field: "file_path", path: "Tests/登录 Tests.swift"),
            try Self.fileToolCall("edit_file", path: "./Sources/../Sources/Auth Service.swift"),
            try Self.fileToolCall("read_file", path: "/tmp/outside/Secret.swift"),
            try Self.fileToolCall("read_file", path: "Sources/", namespace: "mcp_files"),
            shell,
            patch,
            output,
            assistant,
        ])
        let scanner = CodexScanner(codexHome: home)
        let file = try #require(scanner.enumerateFiles()?.first)
        let record = try #require(scanner.parse(
            file,
            includeLaterPrompts: false,
            includeTouchedFiles: true
        ).record)

        #expect(record.touchedFilePaths == ["Sources/Auth Service.swift", "Tests/登录 Tests.swift"])
        let keywords = record.spotlightKeywords(includeTouchedFiles: true)
        #expect(keywords.contains("Auth Service.swift"))
        #expect(keywords.contains("Tests/登录 Tests.swift"))
        #expect(!keywords.joined(separator: " ").contains("Secret.swift"))
    }

    @Test func missingExplicitCwdNeverUsesFallbackHomeForTouchedFiles() throws {
        let metaWithoutCwd = "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"\(Self.uuid)\"}}"
        let home = try makeHome(sessionLines: [
            metaWithoutCwd,
            Self.userMessage("first"),
            try Self.fileToolCall("read_file", path: "Sources/Auth.swift"),
        ])
        let scanner = CodexScanner(codexHome: home)
        let file = try #require(scanner.enumerateFiles()?.first)
        let record = try #require(scanner.parse(
            file,
            includeLaterPrompts: false,
            includeTouchedFiles: true
        ).record)
        #expect(record.touchedFilePaths.isEmpty)
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

    @Test func parsesNestedGitBranchMetadata() throws {
        let home = try makeHome(sessionLines: [
            Self.meta(extra: ",\"git\":{\"branch\":\"codex/issue-13\",\"commit_hash\":\"abc123\"}"),
            Self.userMessage("find this session by branch"),
        ])
        let record = try firstRecord(home: home)
        #expect(record.gitBranch == "codex/issue-13")
    }

    @Test func optionalGitMetadataDegradesSafely() throws {
        let cases: [(extra: String, expected: String?)] = [
            ("", nil),
            (",\"git\":{\"branch\":\"   \"}", nil),
            (",\"git\":\"malformed\"", nil),
            (",\"git\":{\"branch\":42}", nil),
            (",\"git\":{\"detached\":true,\"future_field\":{}}", nil),
        ]

        for item in cases {
            let home = try makeHome(sessionLines: [
                Self.meta(extra: item.extra),
                Self.userMessage("session remains valid"),
            ])
            let record = try firstRecord(home: home)
            #expect(record.gitBranch == item.expected)
            #expect(record.firstPrompt == "session remains valid")
        }
    }

    @Test func spotlightKeywordsIncludeBranchWithoutDuplicates() throws {
        let home = try makeHome(sessionLines: [
            Self.meta(extra: ",\"git\":{\"branch\":\"proj\"}"),
            Self.userMessage("keyword fixture"),
        ])
        let record = try firstRecord(home: home)
        let keywords = record.spotlightKeywords()

        #expect(keywords.filter { $0 == "proj" }.count == 1)
        #expect(record.projectName == "proj")
        #expect(record.firstPrompt == "keyword fixture")
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

    @Test func archivedSourceUsesSameBoundedParserAndStableIdentifier() throws {
        let rel = "archived_sessions/rollout-2026-08-05T18-08-52-\(Self.uuid).jsonl"
        let home = try makeHome(sessionLines: [
            Self.meta(),
            Self.userMessage("first archived prompt"),
            Self.userMessage("distinctive later archived prompt"),
        ], rel: rel)
        let scanner = CodexScanner(codexHome: home, source: .archived)
        let file = try #require(scanner.enumerateFiles()?.first)
        let record = try #require(scanner.parse(file, includeLaterPrompts: true).record)

        #expect(record.id == "codex:\(Self.uuid)")
        #expect(record.isArchived)
        #expect(record.firstPrompt == "first archived prompt")
        #expect(record.laterPromptSnippets == ["distinctive later archived prompt"])
    }

    @Test func archivedSourceRejectsMalformedRollout() throws {
        let rel = "archived_sessions/rollout-2026-08-05T18-08-52-\(Self.uuid).jsonl"
        let home = try makeHome(sessionLines: ["not json", Self.userMessage("no metadata")], rel: rel)
        let scanner = CodexScanner(codexHome: home, source: .archived)
        let file = try #require(scanner.enumerateFiles()?.first)
        #expect(scanner.parse(file).record == nil)
    }

    @Test func watcherPathsIncludeBothCodexLifecycleRoots() {
        let paths = SessionWatchPaths.all(home: URL(fileURLWithPath: "/Users/tester"))
        #expect(paths.contains("/Users/tester/.codex/sessions"))
        #expect(paths.contains("/Users/tester/.codex/archived_sessions"))
        #expect(paths.contains("/Users/tester/.codex/session_index.jsonl"))
    }

    @Test func preFeatureCachedRecordDefaultsToActive() throws {
        let home = try makeHome(sessionLines: [Self.meta(), Self.userMessage("legacy")])
        let original = try firstRecord(home: home)
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isArchived")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: legacy)
        #expect(decoded.isArchived == false)
        #expect(decoded.id == original.id)
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
