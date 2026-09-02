import Foundation

enum ClaudePullRequestResumeError: LocalizedError, Equatable, Sendable {
    case invalidReference
    case claudeDisabled
    case missingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .invalidReference:
            "Pull Request 格式无效。请输入 123、#123 或 https://github.com/owner/repo/pull/123。"
        case .claudeDisabled:
            "Claude Code 索引已在 Spotion 设置中关闭。启用后再重试。"
        case .missingDirectory(let path):
            "项目目录已不存在：\(path)。请选择仍然存在的 Spotion Project。"
        }
    }
}

struct ClaudePullRequestResumePlan: Equatable, Sendable {
    let normalizedReference: String
    let cwd: String
    let terminal: TerminalApp
    let shellCommand: String

    static func make(
        rawReference: String,
        cwd: String,
        claudeEnabled: Bool,
        terminal: TerminalApp,
        resolveBinary: () throws -> String,
        directoryExists: (String) -> Bool
    ) throws -> Self {
        guard claudeEnabled else { throw ClaudePullRequestResumeError.claudeDisabled }
        let reference = try normalize(rawReference)
        guard directoryExists(cwd) else {
            throw ClaudePullRequestResumeError.missingDirectory(cwd)
        }
        let binary = try resolveBinary()
        let command = "cd \(ShellQuoting.posixQuoted(cwd)) && exec \(ShellQuoting.posixQuoted(binary)) --from-pr \(ShellQuoting.posixQuoted(reference))"
        return Self(
            normalizedReference: reference,
            cwd: cwd,
            terminal: terminal,
            shellCommand: command
        )
    }

    static func normalize(_ rawReference: String) throws -> String {
        let raw = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") {
            return try normalizeNumber(String(raw.dropFirst()))
        }
        if raw.utf8.allSatisfy(Self.isASCIIDigit) {
            return try normalizeNumber(raw)
        }

        guard let url = URLComponents(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.percentEncodedQuery == nil,
              url.percentEncodedFragment == nil else {
            throw ClaudePullRequestResumeError.invalidReference
        }
        let parts = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0].isEmpty,
              validRepositorySegment(parts[1]),
              validRepositorySegment(parts[2]),
              parts[3] == "pull" else {
            throw ClaudePullRequestResumeError.invalidReference
        }
        return try normalizeNumber(String(parts[4]))
    }

    private static func normalizeNumber(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.allSatisfy(Self.isASCIIDigit) else {
            throw ClaudePullRequestResumeError.invalidReference
        }
        let withoutLeadingZeros = raw.drop(while: { $0 == "0" })
        guard !withoutLeadingZeros.isEmpty else {
            throw ClaudePullRequestResumeError.invalidReference
        }
        let digits = String(withoutLeadingZeros)
        let maximum = "18446744073709551615"
        guard digits.count < maximum.count || (digits.count == maximum.count && digits <= maximum) else {
            throw ClaudePullRequestResumeError.invalidReference
        }
        return digits
    }

    private static func validRepositorySegment(_ segment: Substring) -> Bool {
        !segment.isEmpty && segment.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 46
                || byte == 95
        }
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }
}
