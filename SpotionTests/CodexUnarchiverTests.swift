import Foundation
import Testing

@Suite struct CodexUnarchiverTests {
    actor Capture {
        var executable: URL?
        var arguments: [String] = []
        func set(executable: URL, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    struct MissingBinary: LocalizedError {
        var errorDescription: String? { "missing test binary" }
    }

    @Test func passesExecutableAndSessionAsSeparateArguments() async throws {
        let capture = Capture()
        let id = "id with spaces; $(never-a-shell)"
        let unarchiver = CodexUnarchiver(
            resolver: { "/opt/test/codex" },
            runner: { executable, arguments, _ in
                await capture.set(executable: executable, arguments: arguments)
                return CodexProcessResult(terminationStatus: 0, stdout: "", stderr: "")
            }
        )
        try await unarchiver.unarchive(sessionID: id)
        #expect(await capture.executable?.path == "/opt/test/codex")
        #expect(await capture.arguments == ["unarchive", id])
    }

    @Test func missingBinaryPreventsProcessLaunch() async {
        let capture = Capture()
        let unarchiver = CodexUnarchiver(
            resolver: { throw MissingBinary() },
            runner: { executable, arguments, _ in
                await capture.set(executable: executable, arguments: arguments)
                return CodexProcessResult(terminationStatus: 0, stdout: "", stderr: "")
            }
        )
        await #expect(throws: MissingBinary.self) {
            try await unarchiver.unarchive(sessionID: "session")
        }
        #expect(await capture.executable == nil)
    }

    @Test func nonzeroExitSurfacesBoundedStderr() async {
        let diagnostic = String(repeating: "E", count: 10_000)
        let unarchiver = CodexUnarchiver(
            resolver: { "/opt/test/codex" },
            runner: { _, _, _ in
                CodexProcessResult(terminationStatus: 9, stdout: "ignored", stderr: diagnostic)
            }
        )
        do {
            try await unarchiver.unarchive(sessionID: "session")
            Issue.record("Expected a nonzero exit to throw")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("exit 9"))
            #expect(message.count < 4_200)
        }
    }

    @Test func timeoutAndCancellationPropagate() async {
        let timedOut = CodexUnarchiver(
            resolver: { "/opt/test/codex" },
            runner: { _, _, _ in throw CodexProcessRunner.TimeoutError(seconds: 1) }
        )
        await #expect(throws: CodexProcessRunner.TimeoutError.self) {
            try await timedOut.unarchive(sessionID: "session")
        }

        let cancellable = CodexUnarchiver(
            resolver: { "/opt/test/codex" },
            runner: { _, _, _ in
                try await Task.sleep(for: .seconds(60))
                return CodexProcessResult(terminationStatus: 0, stdout: "", stderr: "")
            }
        )
        let task = Task { try await cancellable.unarchive(sessionID: "session") }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func liveRunnerBoundsOutputAndTimesOut() async throws {
        let runner = CodexProcessRunner()
        let output = String(repeating: "x", count: CodexProcessRunner.maximumCapturedBytes * 2)
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", output],
            timeout: .seconds(2)
        )
        #expect(result.terminationStatus == 0)
        #expect(result.stdout.contains("[output truncated]"))
        #expect(result.stdout.count < CodexProcessRunner.maximumCapturedBytes + 40)

        await #expect(throws: CodexProcessRunner.TimeoutError.self) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: .milliseconds(20)
            )
        }


        let cancellation = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: .seconds(5)
            )
        }
        try? await Task.sleep(for: .milliseconds(20))
        cancellation.cancel()
        await #expect(throws: CancellationError.self) { try await cancellation.value }
    }

    @Test @MainActor func resumeDispatchRequiresFreshActiveRecord() async throws {
        let archived = makeRecord(isArchived: true)
        var dispatched: [LaunchDestination] = []
        let terminalGate = ArchivedSessionResumeGate(
            unarchive: { _ in },
            refreshRecord: { _ in self.makeRecord(isArchived: false) },
            dispatch: { _ in
                let destination = LaunchDestination.terminal(.terminal)
                dispatched.append(destination)
                return destination
            }
        )
        #expect(try await terminalGate.resume(archived) == .terminal(.terminal))

        let nativeGate = ArchivedSessionResumeGate(
            unarchive: { _ in },
            refreshRecord: { _ in self.makeRecord(isArchived: false) },
            dispatch: { _ in
                let destination = LaunchDestination.nativeApp(appName: "ChatGPT")
                dispatched.append(destination)
                return destination
            }
        )
        #expect(try await nativeGate.resume(archived) == .nativeApp(appName: "ChatGPT"))
        #expect(dispatched.count == 2)

        let stillArchived = ArchivedSessionResumeGate(
            unarchive: { _ in },
            refreshRecord: { _ in self.makeRecord(isArchived: true) },
            dispatch: { _ in
                Issue.record("Dispatch must not run while archive state remains authoritative")
                return .terminal(.terminal)
            }
        )
        await #expect(throws: ArchivedSessionResumeGate.StillArchivedError.self) {
            try await stillArchived.resume(archived)
        }

        let failed = ArchivedSessionResumeGate(
            unarchive: { _ in throw MissingBinary() },
            refreshRecord: { _ in
                Issue.record("Refresh must not run after failed unarchive")
                return nil
            },
            dispatch: { _ in
                Issue.record("Dispatch must not run after failed unarchive")
                return .terminal(.terminal)
            }
        )
        await #expect(throws: MissingBinary.self) { try await failed.resume(archived) }
    }

    private func makeRecord(isArchived: Bool) -> SessionRecord {
        SessionRecord(
            id: "codex:session",
            agent: .codex,
            sessionID: "session",
            fallbackTitle: nil,
            firstPrompt: "prompt",
            laterPromptSnippets: [],
            isArchived: isArchived,
            cwd: "/tmp/project",
            projectName: "project",
            gitBranch: nil,
            startedAt: nil,
            lastActivityAt: Date(timeIntervalSince1970: 1),
            filePath: "/tmp/rollout.jsonl",
            fileSize: 1
        )
    }
}
