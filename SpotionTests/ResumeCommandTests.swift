import Foundation
import Testing

@Suite(.serialized)
struct ResumeCommandTests {
    private struct StubResolver: AgentBinaryResolving {
        struct Missing: Error {}
        var executable: String?

        func resolve(_ agent: AgentKind) throws -> String {
            guard let executable else { throw Missing() }
            return executable
        }
    }

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
        cwd: String = "/tmp/Project One"
    ) -> SessionRecord {
        SessionRecord(
            id: SessionRecord.makeID(agent: agent, sessionID: sessionID),
            agent: agent,
            sessionID: sessionID,
            fallbackTitle: "Test session",
            firstPrompt: nil,
            laterPromptSnippets: [],
            cwd: cwd,
            projectName: "Project One",
            gitBranch: nil,
            startedAt: nil,
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
            filePath: "/tmp/session.jsonl",
            fileSize: 1
        )
    }

    @Test
    func buildsCodexAndClaudeCommandsWithExistingDirectories() throws {
        let builder = ResumeCommandBuilder(directoryExists: { $0 == "/tmp/Project One" })
        let codex = try builder.command(
            for: record(agent: .codex), executable: "/Applications/ChatGPT.app/Contents/Resources/codex")
        let claude = try builder.command(
            for: record(agent: .claude), executable: "/Users/test/.local/bin/claude")

        #expect(codex == "cd '/tmp/Project One' && exec '/Applications/ChatGPT.app/Contents/Resources/codex' --cd '/tmp/Project One' resume '37820960-9057-4bd4-9c9f-47cfa12b9bf0'")
        #expect(claude == "cd '/tmp/Project One' && exec '/Users/test/.local/bin/claude' --resume '37820960-9057-4bd4-9c9f-47cfa12b9bf0'")
    }

    @Test
    func quotesEveryDynamicValueAsShellData() throws {
        let cwd = "/tmp/Project 'β'\nnext"
        let executable = "/tmp/bin '工具'\nrun"
        let sessionID = "--danger; $(touch /tmp/pwn) 'quoted'\n下一行"
        let builder = ResumeCommandBuilder(directoryExists: { $0 == cwd })

        let command = try builder.command(
            for: record(agent: .codex, sessionID: sessionID, cwd: cwd), executable: executable)

        #expect(command == "cd \(ShellQuoting.posixQuoted(cwd)) && exec \(ShellQuoting.posixQuoted(executable)) --cd \(ShellQuoting.posixQuoted(cwd)) resume \(ShellQuoting.posixQuoted(sessionID))")
        #expect(command.contains("'\\''"))
        #expect(!command.contains("resume --danger"))
    }

    @Test
    func codexFallsBackWhenCwdIsMissingButClaudeFails() throws {
        let builder = ResumeCommandBuilder(directoryExists: { _ in false })
        let codex = try builder.command(for: record(agent: .codex), executable: "/bin/codex")
        #expect(codex == "exec '/bin/codex' resume '37820960-9057-4bd4-9c9f-47cfa12b9bf0'")

        do {
            _ = try builder.command(for: record(agent: .claude), executable: "/bin/claude")
            Issue.record("Expected a missing-directory error")
        } catch let error as ResumeCommandBuilder.MissingWorkingDirectoryError {
            #expect(error.path == "/tmp/Project One")
        }
    }

    @Test
    func resolverPrefersConfiguredOverrideAndExpandsTilde() throws {
        let resolver = AgentBinaryResolver(
            overridePath: { _ in "~/Custom Tools/codex" },
            homeDirectory: "/Users/test",
            searchPath: "/other/bin",
            executableCheck: { $0 == "/Users/test/Custom Tools/codex" }
        )
        #expect(try resolver.resolve(.codex) == "/Users/test/Custom Tools/codex")
    }

    @Test
    func resolverFindsExecutableFromPathWithoutStartingAShell() throws {
        let resolver = AgentBinaryResolver(
            overridePath: { _ in nil },
            homeDirectory: "/Users/test",
            searchPath: "/missing:/custom tools/bin:/also-missing",
            executableCheck: { $0 == "/custom tools/bin/claude" }
        )

        #expect(try resolver.resolve(.claude) == "/custom tools/bin/claude")
    }

    @Test
    func resolverReportsMissingExecutableAfterBoundedFilesystemChecks() {
        let resolver = AgentBinaryResolver(
            overridePath: { _ in "/configured/missing/codex" },
            homeDirectory: "/Users/test",
            searchPath: "/missing:/also-missing",
            executableCheck: { _ in false }
        )

        do {
            _ = try resolver.resolve(.codex)
            Issue.record("Expected executable resolution to fail")
        } catch let error as AgentBinaryResolver.NotFoundError {
            #expect(error.agent == .codex)
            #expect(error.tried.contains("/configured/missing/codex"))
            #expect(error.tried.contains("/missing/codex"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test
    func terminalAndCopyPathsProduceTheSameCommandAndOneClipboardWrite() throws {
        let builder = ResumeCommandBuilder(directoryExists: { _ in true })
        let service = ResumeCommandService(
            resolver: StubResolver(executable: "/opt/bin/codex"), builder: builder)
        let terminal = TerminalLauncher(commandService: service)
        let clipboard = ClipboardSpy()
        let session = record(agent: .codex)

        let launchedCommand = try terminal.resumeCommand(for: session)
        let copiedCommand = try ResumeCommandCopier(commandService: service).copy(session, to: clipboard)

        #expect(copiedCommand == launchedCommand)
        #expect(clipboard.writes == [copiedCommand])
    }

    @MainActor
    @Test
    func resolutionAndRequiredDirectoryFailuresLeaveClipboardUntouched() throws {
        let clipboard = ClipboardSpy()
        let missingExecutable = ResumeCommandService(
            resolver: StubResolver(executable: nil),
            builder: ResumeCommandBuilder(directoryExists: { _ in true })
        )
        do {
            _ = try ResumeCommandCopier(commandService: missingExecutable)
                .copy(record(agent: .codex), to: clipboard)
            Issue.record("Expected executable resolution to fail")
        } catch {
            #expect(error is StubResolver.Missing)
        }
        #expect(clipboard.writes.isEmpty)

        let missingCwd = ResumeCommandService(
            resolver: StubResolver(executable: "/bin/claude"),
            builder: ResumeCommandBuilder(directoryExists: { _ in false })
        )
        do {
            _ = try ResumeCommandCopier(commandService: missingCwd)
                .copy(record(agent: .claude), to: clipboard)
            Issue.record("Expected Claude cwd validation to fail")
        } catch {
            #expect(error is ResumeCommandBuilder.MissingWorkingDirectoryError)
        }
        #expect(clipboard.writes.isEmpty)
    }

    @Test
    func launchPreferencesDoNotChangeCommandConstruction() throws {
        let defaults = UserDefaults.standard
        let keys = ["terminalApp", "launchTarget.codex"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] as? String {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let service = ResumeCommandService(
            resolver: StubResolver(executable: "/bin/codex"),
            builder: ResumeCommandBuilder(directoryExists: { _ in true })
        )
        SpotionSettings.terminal = .terminal
        SpotionSettings.setLaunchTarget(.nativeApp, for: .codex)
        let nativePreference = try service.command(for: record(agent: .codex))

        SpotionSettings.terminal = .ghostty
        SpotionSettings.setLaunchTarget(.cli, for: .codex)
        let cliPreference = try service.command(for: record(agent: .codex))

        #expect(nativePreference == cliPreference)
    }
}
