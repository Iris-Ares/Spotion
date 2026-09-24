import Foundation

/// Pure shell-command construction shared by the terminal launcher and its
/// hostless tests. The caller resolves the binary and determines whether the
/// saved cwd still exists; this type never touches the filesystem or a session.
enum SessionLaunchCommand {
    struct MissingDirectoryError: LocalizedError, Equatable {
        var path: String

        var errorDescription: String? {
            "会话目录已不存在：\(path)（claude --resume 必须在原目录运行）"
        }
    }

    static func resume(
        _ record: SessionRecord,
        binary: String,
        existingDirectory cwd: String?
    ) throws -> String {
        let executable = environmentWrappedExecutable(for: record, binary: binary)
        switch record.agent {
        case .codex:
            if let cwd {
                // Official docs: --cd takes precedence over the saved session dir.
                return "cd \(q(cwd)) && exec \(executable) --cd \(q(cwd)) resume \(q(record.sessionID))"
            }
            // Original directory is gone: defer to Codex's saved-dir logic.
            return "exec \(executable) resume \(q(record.sessionID))"
        case .claude:
            // claude --resume has no cwd flag and lookup is scoped to the
            // process cwd, so a missing directory cannot safely fall back.
            guard let cwd else { throw MissingDirectoryError(path: record.cwd) }
            return "cd \(q(cwd)) && exec \(executable) --resume \(q(record.sessionID))"
        }
    }

    static func fork(
        _ record: SessionRecord,
        binary: String,
        existingDirectory cwd: String?
    ) throws -> String {
        let executable = environmentWrappedExecutable(for: record, binary: binary)
        switch record.agent {
        case .codex:
            // `--` keeps even a leading-dash identifier positional. Codex can
            // still recover its saved cwd when the original directory vanished.
            let fork = "exec \(executable) fork -- \(q(record.sessionID))"
            guard let cwd else { return fork }
            return "cd \(q(cwd)) && exec \(executable) --cd \(q(cwd)) fork -- \(q(record.sessionID))"
        case .claude:
            guard let cwd else { throw MissingDirectoryError(path: record.cwd) }
            // Long-option assignment keeps a leading-dash identifier bound to
            // --resume instead of letting the CLI reinterpret it as an option.
            return "cd \(q(cwd)) && exec \(executable) --resume=\(q(record.sessionID)) --fork-session"
        }
    }

    private static func environmentWrappedExecutable(for record: SessionRecord, binary: String) -> String {
        guard !record.isDefaultAgentHome else { return q(binary) }
        let assignment = "\(record.agent.homeEnvironmentVariable)=\(record.agentHomePath)"
        return "env \(q(assignment)) \(q(binary))"
    }

    private static func q(_ value: String) -> String {
        ShellQuoting.posixQuoted(value)
    }
}
