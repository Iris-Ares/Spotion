import Foundation

/// Pure construction shared by terminal resume and the copy-command intent.
/// It performs no process, terminal, native-app, or clipboard operation.
struct ResumeCommandBuilder: Sendable {
    struct MissingWorkingDirectoryError: LocalizedError, Equatable {
        var path: String

        var errorDescription: String? {
            "会话目录已不存在：\(path)（claude --resume 必须在原目录运行）"
        }
    }

    private let directoryExists: @Sendable (String) -> Bool

    init(directoryExists: @escaping @Sendable (String) -> Bool = Self.directoryExists) {
        self.directoryExists = directoryExists
    }

    func command(for record: SessionRecord, executable: String) throws -> String {
        let binary = ShellQuoting.posixQuoted(executable)
        let sessionID = ShellQuoting.posixQuoted(record.sessionID)

        switch record.agent {
        case .codex:
            guard directoryExists(record.cwd) else {
                // Original directory is gone: defer to Codex's saved-directory logic.
                return "exec \(binary) resume \(sessionID)"
            }
            let cwd = ShellQuoting.posixQuoted(record.cwd)
            // Official docs: --cd takes precedence over the saved session directory.
            return "cd \(cwd) && exec \(binary) --cd \(cwd) resume \(sessionID)"
        case .claude:
            // claude --resume has no cwd flag and session lookup is scoped to
            // the process cwd, so the directory is mandatory.
            guard directoryExists(record.cwd) else {
                throw MissingWorkingDirectoryError(path: record.cwd)
            }
            let cwd = ShellQuoting.posixQuoted(record.cwd)
            return "cd \(cwd) && exec \(binary) --resume \(sessionID)"
        }
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// Resolves the executable and constructs a command. Both launch and copy use
/// this same service so their agent syntax, cwd rules, and quoting cannot drift.
struct ResumeCommandService: Sendable {
    static let shared = ResumeCommandService()

    private let resolver: any AgentBinaryResolving
    private let builder: ResumeCommandBuilder

    init(
        resolver: any AgentBinaryResolving = AgentBinaryResolver(),
        builder: ResumeCommandBuilder = ResumeCommandBuilder()
    ) {
        self.resolver = resolver
        self.builder = builder
    }

    func command(for record: SessionRecord) throws -> String {
        try builder.command(for: record, executable: resolver.resolve(record.agent))
    }

    func executable(for agent: AgentKind) throws -> String {
        try resolver.resolve(agent)
    }
}
