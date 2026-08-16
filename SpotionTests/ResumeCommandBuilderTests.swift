import Foundation
import Testing

@Suite struct ResumeCommandBuilderTests {
    private func record(
        agent: AgentKind,
        home: String,
        isDefault: Bool,
        cwd: String = "/tmp/project's work"
    ) -> SessionRecord {
        SessionRecord(
            id: SessionRecord.makeID(
                agent: agent,
                sessionID: "session-id",
                agentHomePath: home,
                isDefaultAgentHome: isDefault
            ),
            agent: agent,
            sessionID: "session-id",
            agentHomePath: home,
            isDefaultAgentHome: isDefault,
            fallbackTitle: nil,
            firstPrompt: nil,
            laterPromptSnippets: [],
            cwd: cwd,
            projectName: "work",
            gitBranch: nil,
            startedAt: nil,
            lastActivityAt: .now,
            filePath: "/tmp/session.jsonl",
            fileSize: 1
        )
    }

    @Test func alternateCodexHomeIsScopedToResumeChildWithSafeQuoting() throws {
        let source = record(agent: .codex, home: "/tmp/-work profile's Codex", isDefault: false)
        let command = try #require(ResumeCommandBuilder.command(
            for: source,
            binary: "/Applications/Agent Tools/codex",
            existingCwd: source.cwd
        ))

        #expect(command.contains("exec env 'CODEX_HOME=/tmp/-work profile'\\''s Codex' '/Applications/Agent Tools/codex'"))
        #expect(command.contains("--cd '/tmp/project'\\''s work' resume 'session-id'"))
        #expect(!command.contains("export CODEX_HOME"))
    }

    @Test func alternateClaudeHomeUsesDocumentedVariableAndRequiresCwd() throws {
        let source = record(agent: .claude, home: "/tmp/Claude 配置", isDefault: false)
        let command = try #require(ResumeCommandBuilder.command(
            for: source,
            binary: "/usr/local/bin/claude",
            existingCwd: source.cwd
        ))

        #expect(command.contains("exec env 'CLAUDE_CONFIG_DIR=/tmp/Claude 配置' '/usr/local/bin/claude'"))
        #expect(command.hasSuffix("--resume 'session-id'"))
        #expect(ResumeCommandBuilder.command(for: source, binary: "/bin/claude", existingCwd: nil) == nil)
    }

    @Test func defaultHomeResumeDoesNotInjectEnvironment() throws {
        let source = record(agent: .codex, home: "/Users/test/.codex", isDefault: true)
        let command = try #require(ResumeCommandBuilder.command(
            for: source,
            binary: "/bin/codex",
            existingCwd: nil
        ))

        #expect(command == "exec '/bin/codex' resume 'session-id'")
        #expect(!command.contains("CODEX_HOME"))
    }
}
