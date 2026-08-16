import Foundation
import Testing

@Suite struct SessionLaunchCommandTests {
    private func record(
        agent: AgentKind,
        id: String = "37820960-9057-4bd4-9c9f-47cfa12b9bf0",
        cwd: String = "/tmp/project",
        home: String? = nil,
        isDefaultHome: Bool = true
    ) -> SessionRecord {
        SessionRecord(
            id: SessionRecord.makeID(agent: agent, sessionID: id),
            agent: agent,
            sessionID: id,
            agentHomePath: home,
            isDefaultAgentHome: isDefaultHome,
            fallbackTitle: nil,
            firstPrompt: "prompt",
            laterPromptSnippets: [],
            cwd: cwd,
            projectName: "project",
            gitBranch: nil,
            startedAt: nil,
            lastActivityAt: Date(timeIntervalSince1970: 1),
            filePath: "/tmp/session.jsonl",
            fileSize: 1
        )
    }

    @Test func codexForkUsesExactSelectedIDAndExistingCWD() throws {
        let source = record(agent: .codex)
        let command = try SessionLaunchCommand.fork(
            source, binary: "/opt/bin/codex", existingDirectory: source.cwd)

        #expect(command == "cd '/tmp/project' && exec '/opt/bin/codex' --cd '/tmp/project' fork -- '37820960-9057-4bd4-9c9f-47cfa12b9bf0'")
        #expect(command.contains("fork -- '\(source.sessionID)'"))
        #expect(!command.contains("--last"))
        #expect(source == record(agent: .codex))
    }

    @Test func codexForkFallsBackWhenCWDIsMissing() throws {
        let source = record(agent: .codex, cwd: "/removed/project")
        let command = try SessionLaunchCommand.fork(
            source, binary: "/opt/bin/codex", existingDirectory: nil)

        #expect(command == "exec '/opt/bin/codex' fork -- '37820960-9057-4bd4-9c9f-47cfa12b9bf0'")
    }

    @Test func claudeForkUsesExactSelectedIDAndExistingCWD() throws {
        let source = record(agent: .claude)
        let command = try SessionLaunchCommand.fork(
            source, binary: "/opt/bin/claude", existingDirectory: source.cwd)

        #expect(command == "cd '/tmp/project' && exec '/opt/bin/claude' --resume='37820960-9057-4bd4-9c9f-47cfa12b9bf0' --fork-session")
        #expect(!command.contains("--continue"))
        #expect(source == record(agent: .claude))
    }

    @Test func claudeForkRejectsMissingCWD() {
        let source = record(agent: .claude, cwd: "/removed/project")

        #expect(throws: SessionLaunchCommand.MissingDirectoryError(path: source.cwd)) {
            try SessionLaunchCommand.fork(
                source, binary: "/opt/bin/claude", existingDirectory: nil)
        }
    }

    @Test func forkCommandsQuoteSpacesApostrophesAndLeadingDashIDs() throws {
        let cwd = "/tmp/A project's worktree"
        let binary = "/tmp/Agent tools/codex's binary"
        let codex = try SessionLaunchCommand.fork(
            record(agent: .codex, id: "-selected-session", cwd: cwd),
            binary: binary,
            existingDirectory: cwd
        )
        #expect(codex == "cd '/tmp/A project'\\''s worktree' && exec '/tmp/Agent tools/codex'\\''s binary' --cd '/tmp/A project'\\''s worktree' fork -- '-selected-session'")

        let claude = try SessionLaunchCommand.fork(
            record(agent: .claude, id: "-selected-session", cwd: cwd),
            binary: "/tmp/Agent tools/claude",
            existingDirectory: cwd
        )
        #expect(claude.contains("--resume='-selected-session' --fork-session"))
    }

    @Test func resumeCommandConstructionIsUnchanged() throws {
        let codex = record(agent: .codex)
        #expect(try SessionLaunchCommand.resume(
            codex, binary: "/opt/bin/codex", existingDirectory: codex.cwd
        ) == "cd '/tmp/project' && exec '/opt/bin/codex' --cd '/tmp/project' resume '37820960-9057-4bd4-9c9f-47cfa12b9bf0'")
        #expect(try SessionLaunchCommand.resume(
            codex, binary: "/opt/bin/codex", existingDirectory: nil
        ) == "exec '/opt/bin/codex' resume '37820960-9057-4bd4-9c9f-47cfa12b9bf0'")

        let claude = record(agent: .claude)
        #expect(try SessionLaunchCommand.resume(
            claude, binary: "/opt/bin/claude", existingDirectory: claude.cwd
        ) == "cd '/tmp/project' && exec '/opt/bin/claude' --resume '37820960-9057-4bd4-9c9f-47cfa12b9bf0'")
    }

    @Test func alternateCodexHomeScopesResumeForkAndCopiedCommand() throws {
        let source = record(
            agent: .codex,
            cwd: "/tmp/project's work",
            home: "/tmp/-work profile's Codex",
            isDefaultHome: false)
        let executable = "env 'CODEX_HOME=/tmp/-work profile'\''s Codex' '/Applications/Agent Tools/codex'"

        let resume = try SessionLaunchCommand.resume(
            source, binary: "/Applications/Agent Tools/codex", existingDirectory: source.cwd)
        let fork = try SessionLaunchCommand.fork(
            source, binary: "/Applications/Agent Tools/codex", existingDirectory: source.cwd)

        #expect(resume.contains("exec \(executable) --cd '/tmp/project'\''s work' resume"))
        #expect(fork.contains("exec \(executable) --cd '/tmp/project'\''s work' fork --"))
        #expect(!resume.contains("export CODEX_HOME"))
    }

    @Test func alternateClaudeHomeScopesResumeAndFork() throws {
        let source = record(
            agent: .claude,
            home: "/tmp/Claude 配置",
            isDefaultHome: false)
        let executable = "env 'CLAUDE_CONFIG_DIR=/tmp/Claude 配置' '/usr/local/bin/claude'"

        #expect(try SessionLaunchCommand.resume(
            source, binary: "/usr/local/bin/claude", existingDirectory: source.cwd
        ).contains("exec \(executable) --resume"))
        #expect(try SessionLaunchCommand.fork(
            source, binary: "/usr/local/bin/claude", existingDirectory: source.cwd
        ).contains("exec \(executable) --resume="))
    }
}
