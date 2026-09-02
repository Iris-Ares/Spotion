import AppKit
import Foundation

/// Translates "resume / fork / start a session" into one shell command
/// and launches it in a terminal.
/// Terminal.app: NSAppleScript `do script` (default; triggers the Automation
/// consent prompt on first use).
/// Ghostty: `open -na Ghostty.app --args -e /bin/zsh -c <command>` (argv passed
/// through verbatim, no second shell expansion).
final class TerminalLauncher: Sendable {
    static let shared = TerminalLauncher()

    struct LaunchError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private let resolver = AgentBinaryResolver()

    func resume(_ record: SessionRecord) async throws {
        let binary = try resolver.resolve(record.agent)
        let command = try SessionLaunchCommand.resume(
            record, binary: binary, existingDirectory: existingDirectory(record.cwd))
        try await launch(shellCommand: command)
    }

    /// Fork is deliberately terminal-only: neither supported native-app deep
    /// link exposes an explicit, source-preserving fork contract.
    func fork(_ record: SessionRecord) async throws {
        let binary = try resolver.resolve(record.agent)
        let command = try SessionLaunchCommand.fork(
            record, binary: binary, existingDirectory: existingDirectory(record.cwd))
        try await launch(shellCommand: command)
    }

    func startNew(agent: AgentKind, prompt: String, cwd rawCwd: String) async throws {
        let binary = try resolver.resolve(agent)
        // Expand "~" (the settings field may hold an unexpanded path) and
        // reject missing directories instead of silently substituting $HOME —
        // the intent dialog names the requested project, so a silent fallback
        // would start the session somewhere the user did not ask for.
        let expanded = (rawCwd as NSString).expandingTildeInPath
        guard let cwd = existingDirectory(expanded) else {
            throw LaunchError(message: "目录不存在：\(rawCwd)。请在 Spotlight 里选择有效的 Project，或到 Spotion 设置里修正默认目录。")
        }
        // "--" terminates option parsing (clap/commander convention): a prompt
        // beginning with "-" must reach the CLI as the positional prompt, not
        // be parsed as an option (e.g. "-p" would otherwise exit with a
        // missing-profile-value error instead of starting a session).
        let command = switch agent {
        case .codex:
            "cd \(q(cwd)) && exec \(q(binary)) --cd \(q(cwd)) -- \(q(prompt))"
        case .claude:
            "cd \(q(cwd)) && exec \(q(binary)) -- \(q(prompt))"
        }
        try await launch(shellCommand: command)
    }

    // MARK: - Terminal dispatch

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

    // MARK: - Helpers

    private func existingDirectory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }

    private func q(_ s: String) -> String { ShellQuoting.posixQuoted(s) }
}
