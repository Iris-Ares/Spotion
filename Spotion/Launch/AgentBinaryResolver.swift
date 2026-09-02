import Foundation

/// Resolved fresh on every launch action (never cached): the codex binary
/// drifts with ChatGPT.app updates, and claude moves across version switches.
/// Order: settings override → known install locations → common bin dirs →
/// the app process's PATH → login-shell `command -v`.
/// The shell fallback is not optional polish: an LSUIElement app inherits the
/// LaunchServices PATH (`/usr/bin:/bin:…`), so a claude installed through nvm,
/// volta, bun, or asdf is only reachable via the user's login shell.
struct AgentBinaryResolver: Sendable {
    struct NotFoundError: LocalizedError {
        var agent: AgentKind
        var tried: [String]
        var errorDescription: String? {
            "找不到 \(agent.displayName) 可执行文件。已尝试：\(tried.joined(separator: ", "))。可在 Spotion 设置 → Advanced 里手动指定路径。"
        }
    }

    private let overridePath: @Sendable (AgentKind) -> String?
    private let homeDirectory: String
    private let searchPath: String?
    private let executableCheck: @Sendable (String) -> Bool
    private let shellLookup: @Sendable (String) -> String?

    init(
        overridePath: @escaping @Sendable (AgentKind) -> String? = Self.configuredOverride,
        homeDirectory: String = NSHomeDirectory(),
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        executableCheck: @escaping @Sendable (String) -> Bool = Self.isExecutable,
        shellLookup: @escaping @Sendable (String) -> String? = Self.loginShellLookup
    ) {
        self.overridePath = overridePath
        self.homeDirectory = homeDirectory
        self.searchPath = searchPath
        self.executableCheck = executableCheck
        self.shellLookup = shellLookup
    }

    func resolve(_ agent: AgentKind) throws -> String {
        var tried: [String] = []

        if let override = overridePath(agent) {
            // The settings field may hold an unexpanded "~/..." path — expand
            // before checking, or a valid override would be silently bypassed.
            let expanded = override.hasPrefix("~/")
                ? homeDirectory + String(override.dropFirst())
                : (override as NSString).expandingTildeInPath
            if executableCheck(expanded) { return expanded }
            tried.append(override)
        }

        let known: [String] = switch agent {
        case .codex: ["/Applications/ChatGPT.app/Contents/Resources/codex"]
        case .claude: ["\(homeDirectory)/.local/bin/claude"]
        }
        let common = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(homeDirectory)/.local/bin", "\(homeDirectory)/bin",
        ]
            .map { "\($0)/\(agent.rawValue)" }
        let pathCandidates = (searchPath ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { "\($0)/\(agent.rawValue)" }

        var seen = Set<String>()
        for candidate in known + common + pathCandidates where seen.insert(candidate).inserted {
            if executableCheck(candidate) { return candidate }
            tried.append(candidate)
        }

        if let found = shellLookup(agent.rawValue), executableCheck(found) {
            return found
        }
        tried.append("$PATH (login shell)")
        throw NotFoundError(agent: agent, tried: tried)
    }

    private static func configuredOverride(_ agent: AgentKind) -> String? {
        agent == .codex ? SpotionSettings.codexPathOverride : SpotionSettings.claudePathOverride
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private static func loginShellLookup(_ name: String) -> String? {
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
