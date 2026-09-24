import Foundation
import Testing

@Suite(.serialized)
struct ResumeCommandTests {
    @MainActor
    private final class ClipboardSpy: PlainTextClipboard {
        var writes: [String] = []

        func replacePlainText(with string: String) throws {
            writes.append(string)
        }
    }

    private func record(
        agent: AgentKind,
        sessionID: String = "37820960-9057-4bd4-9c9f-47cfa12b9bf0",
        cwd: String = "/tmp",
        home: String? = nil,
        isDefaultHome: Bool = true
    ) -> SessionRecord {
        SessionRecord(
            id: SessionRecord.makeID(agent: agent, sessionID: sessionID),
            agent: agent,
            sessionID: sessionID,
            agentHomePath: home,
            isDefaultAgentHome: isDefaultHome,
            fallbackTitle: "Test session",
            firstPrompt: nil,
            laterPromptSnippets: [],
            cwd: cwd,
            projectName: "tmp",
            gitBranch: nil,
            startedAt: nil,
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
            filePath: "/tmp/session.jsonl",
            fileSize: 1
        )
    }

    private func resolver(
        override: String? = nil,
        searchPath: String? = nil,
        executables: Set<String>,
        shell: String? = nil
    ) -> AgentBinaryResolver {
        AgentBinaryResolver(
            overridePath: { _ in override },
            homeDirectory: "/Users/test",
            searchPath: searchPath,
            executableCheck: { executables.contains($0) },
            shellLookup: { _ in shell }
        )
    }

    @Test
    func resolverPrefersConfiguredOverrideAndExpandsTilde() throws {
        let resolver = resolver(
            override: "~/Custom Tools/codex",
            searchPath: "/other/bin",
            executables: ["/Users/test/Custom Tools/codex"])
        #expect(try resolver.resolve(.codex) == "/Users/test/Custom Tools/codex")
    }

    @Test
    func resolverFindsExecutableFromProcessPath() throws {
        let resolver = resolver(
            searchPath: "/missing:/custom tools/bin:/also-missing",
            executables: ["/custom tools/bin/claude"])
        #expect(try resolver.resolve(.claude) == "/custom tools/bin/claude")
    }

    @Test
    func resolverFallsBackToLoginShellForVersionManagers() throws {
        // An LSUIElement process never sees nvm/volta/asdf shims on its own PATH.
        let resolver = resolver(
            searchPath: "/usr/bin:/bin",
            executables: ["/Users/test/.nvm/versions/node/v22/bin/claude"],
            shell: "/Users/test/.nvm/versions/node/v22/bin/claude")
        #expect(try resolver.resolve(.claude) == "/Users/test/.nvm/versions/node/v22/bin/claude")
    }

    @Test
    func resolverReportsEveryLocationTried() {
        let resolver = resolver(override: "/configured/missing/codex", searchPath: "/missing", executables: [])
        do {
            _ = try resolver.resolve(.codex)
            Issue.record("Expected executable resolution to fail")
        } catch let error as AgentBinaryResolver.NotFoundError {
            #expect(error.agent == .codex)
            #expect(error.tried.contains("/configured/missing/codex"))
            #expect(error.tried.contains("/missing/codex"))
            #expect(error.tried.contains("$PATH (login shell)"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test
    func copyWritesExactlyTheLaunchCommandOnce() throws {
        let launcher = TerminalLauncher(resolver: resolver(executables: ["/opt/homebrew/bin/codex"]))
        let clipboard = ClipboardSpy()
        let session = record(agent: .codex)

        let launched = try launcher.resumeCommand(for: session)
        let copied = try ResumeCommandCopier(launcher: launcher).copy(session, to: clipboard)

        #expect(copied == launched)
        #expect(copied == "cd '/tmp' && exec '/opt/homebrew/bin/codex' --cd '/tmp' resume '37820960-9057-4bd4-9c9f-47cfa12b9bf0'")
        #expect(clipboard.writes == [copied])
    }

    @MainActor
    @Test
    func copyPreservesAdditionalHomeEnvironment() throws {
        let launcher = TerminalLauncher(resolver: resolver(executables: ["/opt/homebrew/bin/codex"]))
        let clipboard = ClipboardSpy()
        let session = record(
            agent: .codex,
            home: "/tmp/Codex work",
            isDefaultHome: false)

        let copied = try ResumeCommandCopier(launcher: launcher).copy(session, to: clipboard)

        #expect(copied.contains("exec env 'CODEX_HOME=/tmp/Codex work' '/opt/homebrew/bin/codex'"))
        #expect(clipboard.writes == [copied])
    }

    @MainActor
    @Test
    func resolutionAndRequiredDirectoryFailuresLeaveClipboardUntouched() throws {
        let clipboard = ClipboardSpy()

        let noBinary = ResumeCommandCopier(launcher: TerminalLauncher(resolver: resolver(executables: [])))
        do {
            _ = try noBinary.copy(record(agent: .codex), to: clipboard)
            Issue.record("Expected executable resolution to fail")
        } catch {
            #expect(error is AgentBinaryResolver.NotFoundError)
        }
        #expect(clipboard.writes.isEmpty)

        let missingCwd = ResumeCommandCopier(
            launcher: TerminalLauncher(resolver: resolver(executables: ["/opt/homebrew/bin/claude"])))
        do {
            _ = try missingCwd.copy(record(agent: .claude, cwd: "/definitely/not/here"), to: clipboard)
            Issue.record("Expected Claude cwd validation to fail")
        } catch {
            #expect(error is SessionLaunchCommand.MissingDirectoryError)
        }
        #expect(clipboard.writes.isEmpty)
    }
}
