import AppKit
import Foundation

/// 把"resume 会话 / 新建会话"翻译成终端里的一条 shell 命令并拉起终端。
/// Terminal.app：NSAppleScript `do script`（默认，首次触发自动化授权）。
/// Ghostty：`open -na Ghostty.app --args -e /bin/zsh -c <命令>`（argv 直传，无二次 shell 展开）。
final class TerminalLauncher: Sendable {
    static let shared = TerminalLauncher()

    struct LaunchError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private let resolver = AgentBinaryResolver()

    func resume(_ record: SessionRecord) async throws {
        let binary = try resolver.resolve(record.agent)
        let command: String
        switch record.agent {
        case .codex:
            if let cwd = existingDirectory(record.cwd) {
                // --cd 官方文档：优先于会话保存目录
                command = "cd \(q(cwd)) && exec \(q(binary)) --cd \(q(cwd)) resume \(q(record.sessionID))"
            } else {
                // 原目录已消失：交给 codex 自己的会话目录逻辑
                command = "exec \(q(binary)) resume \(q(record.sessionID))"
            }
        case .claude:
            // claude --resume 无 cwd 参数，且会话查找按进程 cwd 定位 → cd 是硬要求
            guard let cwd = existingDirectory(record.cwd) else {
                throw LaunchError(message: "会话目录已不存在：\(record.cwd)（claude --resume 必须在原目录运行）")
            }
            command = "cd \(q(cwd)) && exec \(q(binary)) --resume \(q(record.sessionID))"
        }
        try await launch(shellCommand: command)
    }

    func startNew(agent: AgentKind, prompt: String, cwd rawCwd: String) async throws {
        let binary = try resolver.resolve(agent)
        let cwd = existingDirectory(rawCwd) ?? NSHomeDirectory()
        let command = switch agent {
        case .codex:
            "cd \(q(cwd)) && exec \(q(binary)) --cd \(q(cwd)) \(q(prompt))"
        case .claude:
            "cd \(q(cwd)) && exec \(q(binary)) \(q(prompt))"
        }
        try await launch(shellCommand: command)
    }

    // MARK: - 终端分发

    private func launch(shellCommand: String) async throws {
        switch SpotionSettings.terminal {
        case .terminal:
            try await launchInTerminalApp(shellCommand)
        case .ghostty:
            try launchInGhostty(shellCommand)
        }
    }

    @MainActor
    private func launchInTerminalApp(_ command: String) throws {
        let source = """
        tell application "Terminal"
            activate
            do script "\(ShellQuoting.appleScriptQuoted(command))"
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw LaunchError(message: "无法构建 AppleScript")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let detail = errorInfo[NSAppleScript.errorMessage] as? String ?? String(describing: errorInfo)
            throw LaunchError(message: "Terminal.app 启动失败：\(detail)（检查 系统设置 → 隐私与安全性 → 自动化）")
        }
    }

    private func launchInGhostty(_ command: String) throws {
        guard FileManager.default.fileExists(atPath: "/Applications/Ghostty.app") else {
            throw LaunchError(message: "未找到 /Applications/Ghostty.app，可在设置里切换为 Terminal.app")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", "Ghostty.app", "--args", "-e", "/bin/zsh", "-c", command]
        try process.run()
    }

    // MARK: - 辅助

    private func existingDirectory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }

    private func q(_ s: String) -> String { ShellQuoting.posixQuoted(s) }
}
