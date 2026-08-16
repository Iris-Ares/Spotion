import Foundation

enum ResumeCommandBuilder {
    static func command(
        for record: SessionRecord,
        binary: String,
        existingCwd: String?
    ) -> String? {
        let executable = environmentWrappedExecutable(for: record, binary: binary)
        switch record.agent {
        case .codex:
            if let cwd = existingCwd {
                return "cd \(q(cwd)) && exec \(executable) --cd \(q(cwd)) resume \(q(record.sessionID))"
            }
            return "exec \(executable) resume \(q(record.sessionID))"
        case .claude:
            guard let cwd = existingCwd else { return nil }
            return "cd \(q(cwd)) && exec \(executable) --resume \(q(record.sessionID))"
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
