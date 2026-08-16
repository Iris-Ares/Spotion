import Foundation
import Testing

@Suite struct AgentHomeTests {
    @Test func normalizesDeduplicatesAndRejectsDefaultHome() {
        let defaultCodex = AgentHomePathPolicy.defaultPath(for: .codex)
        let paths = AgentHomePathPolicy.additionalPaths([
            defaultCodex,
            "/tmp/profiles/../profiles/work-codex/",
            "/tmp/profiles/work-codex",
            "relative/home",
            "   ",
        ], for: .codex)

        #expect(paths == ["/tmp/profiles/work-codex"])
    }

    @Test func defaultIDsRemainLegacyWhileAdditionalHomesAreNamespaced() {
        let legacy = SessionRecord.makeID(agent: .codex, sessionID: "same-id")
        let first = SessionRecord.makeID(
            agent: .codex,
            sessionID: "same-id",
            agentHomePath: "/tmp/codex work",
            isDefaultAgentHome: false
        )
        let equivalent = SessionRecord.makeID(
            agent: .codex,
            sessionID: "same-id",
            agentHomePath: "/tmp/./codex work/",
            isDefaultAgentHome: false
        )
        let second = SessionRecord.makeID(
            agent: .codex,
            sessionID: "same-id",
            agentHomePath: "/tmp/codex-personal",
            isDefaultAgentHome: false
        )

        #expect(legacy == "codex:same-id")
        #expect(first == equivalent)
        #expect(first != legacy)
        #expect(first != second)
    }

    @Test func canonicalAliasOfDefaultHomeIsNotAddedAgain() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let realHome = root.appendingPathComponent("real-codex", isDirectory: true)
        let defaultAlias = root.appendingPathComponent("default-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: defaultAlias.path,
            withDestinationPath: realHome.path
        )

        let paths = AgentHomePathPolicy.additionalPaths(
            [realHome.path],
            excludingDefaultPath: defaultAlias.path
        )
        #expect(paths.isEmpty)
    }

    @Test func nativeAppsRejectAdditionalHomesWithActionableSourceContext() {
        let additional = makeRecord(home: "/tmp/work-codex", isDefault: false)
        let defaultHome = makeRecord(home: AgentHomePathPolicy.defaultPath(for: .codex), isDefault: true)

        let reason = NativeAppSourcePolicy.unsupportedReason(for: additional)
        #expect(reason?.contains("/tmp/work-codex") == true)
        #expect(reason?.contains("终端 CLI") == true)
        #expect(NativeAppSourcePolicy.unsupportedReason(for: defaultHome) == nil)
    }

    private func makeRecord(home: String, isDefault: Bool) -> SessionRecord {
        SessionRecord(
            id: SessionRecord.makeID(
                agent: .codex,
                sessionID: "session-id",
                agentHomePath: home,
                isDefaultAgentHome: isDefault
            ),
            agent: .codex,
            sessionID: "session-id",
            agentHomePath: home,
            isDefaultAgentHome: isDefault,
            fallbackTitle: nil,
            firstPrompt: nil,
            laterPromptSnippets: [],
            cwd: "/tmp/project",
            projectName: "project",
            gitBranch: nil,
            startedAt: nil,
            lastActivityAt: .now,
            filePath: "/tmp/session.jsonl",
            fileSize: 1
        )
    }
}
