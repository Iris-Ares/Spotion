import Foundation

/// 每次启动动作时现算（不缓存）：codex 随 ChatGPT.app 更新漂移，claude 随版本切换。
/// 顺序：设置覆盖 → 已知安装位置 → 常见 bin 目录 → 登录 shell `command -v`。
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
