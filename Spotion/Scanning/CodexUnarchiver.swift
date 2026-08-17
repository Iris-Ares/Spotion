import Foundation
import Darwin

struct CodexProcessResult: Sendable {
    var terminationStatus: Int32
    var stdout: String
    var stderr: String
}

/// Runs one executable directly with argv boundaries. Output is redirected to
/// files so a verbose child cannot fill a Pipe and deadlock before timeout.
struct CodexProcessRunner: Sendable {
    struct TimeoutError: LocalizedError {
        var seconds: Int
        var errorDescription: String? {
            "Codex unarchive timed out after \(seconds) seconds. The archived session was not opened."
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var timedOut = false
        init(_ process: Process) { self.process = process }

        func waitUntilExit() -> Int32 {
            process.waitUntilExit()
            return process.terminationStatus
        }

        func terminate(timedOut: Bool = false) {
            lock.lock()
            if timedOut { self.timedOut = true }
            let running = process.isRunning
            let pid = process.processIdentifier
            lock.unlock()
            if running { Darwin.kill(pid, SIGKILL) }
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }
    }

    static let maximumCapturedBytes = 4_096

    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration = .seconds(15)
    ) async throws -> CodexProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotion-unarchive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        let box = ProcessBox(process)
        try process.run()

        let status = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { box.waitUntilExit() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    box.terminate(timedOut: true)
                    return Int32.min
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
        } onCancel: {
            box.terminate()
        }

        if box.didTimeOut {
            throw TimeoutError(seconds: max(1, Int(timeout.components.seconds)))
        }
        try Task.checkCancellation()

        try stdoutHandle.synchronize()
        try stderrHandle.synchronize()
        return CodexProcessResult(
            terminationStatus: status,
            stdout: Self.readBounded(stdoutURL),
            stderr: Self.readBounded(stderrURL)
        )
    }

    private static func readBounded(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maximumCapturedBytes + 1)) ?? Data()
        let bounded = data.prefix(maximumCapturedBytes)
        let suffix = data.count > maximumCapturedBytes ? "\n[output truncated]" : ""
        return String(decoding: bounded, as: UTF8.self) + suffix
    }
}

struct CodexUnarchiver: Sendable {
    typealias Resolver = @Sendable () throws -> String
    typealias Runner = @Sendable (URL, [String], Duration) async throws -> CodexProcessResult

    struct CommandError: LocalizedError {
        var status: Int32
        var detail: String
        var errorDescription: String? {
            let suffix = detail.isEmpty ? "No diagnostic output was returned." : detail
            return "Codex could not unarchive the session (exit \(status)). \(suffix)"
        }
    }

    static let shared = CodexUnarchiver()
    static let outputCharacterLimit = 4_096

    private let resolver: Resolver
    private let runner: Runner
    private let timeout: Duration

    init(
        timeout: Duration = .seconds(15),
        resolver: @escaping Resolver = { try AgentBinaryResolver().resolve(.codex) },
        runner: @escaping Runner = { executable, arguments, timeout in
            try await CodexProcessRunner().run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) {
        self.timeout = timeout
        self.resolver = resolver
        self.runner = runner
    }

    func unarchive(sessionID: String) async throws {
        try Task.checkCancellation()
        let executable = URL(fileURLWithPath: try resolver())
        let result = try await runner(executable, ["unarchive", sessionID], timeout)
        try Task.checkCancellation()
        guard result.terminationStatus == 0 else {
            let raw = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout
                : result.stderr
            throw CommandError(
                status: result.terminationStatus,
                detail: String(raw.prefix(Self.outputCharacterLimit))
            )
        }
    }
}

/// Testable boundary that guarantees dispatch cannot occur until Codex has
/// accepted the unarchive and a fresh scan proves the active source won.
@MainActor
struct ArchivedSessionResumeGate {
    struct StillArchivedError: LocalizedError {
        var sessionID: String
        var errorDescription: String? {
            "Codex reported success, but session \(sessionID) is still archived or missing. It was not opened."
        }
    }

    var unarchive: (String) async throws -> Void
    var refreshRecord: (String) async -> SessionRecord?
    var dispatch: (SessionRecord) async throws -> LaunchDestination

    func resume(_ record: SessionRecord) async throws -> LaunchDestination {
        try await unarchive(record.sessionID)
        guard let refreshed = await refreshRecord(record.id), !refreshed.isArchived else {
            throw StillArchivedError(sessionID: record.sessionID)
        }
        return try await dispatch(refreshed)
    }
}
