import Foundation

/// Resolved fresh on every launch action (never cached): the codex binary
/// drifts with ChatGPT.app updates, and claude moves across version switches.
/// Order: settings override → known install locations → common bin dirs →
/// login-shell `command -v`.
struct AgentBinaryResolver: Sendable {
    struct NotFoundError: LocalizedError {
        var agent: AgentKind
        var tried: [String]
        var errorDescription: String? {
            "找不到 \(agent.displayName) 可执行文件。已尝试：\(tried.joined(separator: ", "))。可在 Spotion 设置 → Advanced 里手动指定路径。"
        }
    }

    func resolve(_ agent: AgentKind) throws -> String {
        var tried: [String] = []
        let home = NSHomeDirectory()

        let override = agent == .codex ? SpotionSettings.codexPathOverride : SpotionSettings.claudePathOverride
        if let override {
            if isExecutable(override) { return override }
            tried.append(override)
        }

        let known: [String] = switch agent {
        case .codex: ["/Applications/ChatGPT.app/Contents/Resources/codex"]
        case .claude: ["\(home)/.local/bin/claude"]
        }
        let common = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"]
            .map { "\($0)/\(agent.rawValue)" }

        for candidate in known + common {
            if isExecutable(candidate) { return candidate }
            tried.append(candidate)
        }

        if let found = loginShellLookup(agent.rawValue), isExecutable(found) {
            return found
        }
        tried.append("$PATH (login shell)")
        throw NotFoundError(agent: agent, tried: tried)
    }

    private func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private func loginShellLookup(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.trimmingCharacters(in: .whitespaces)
    }
}
