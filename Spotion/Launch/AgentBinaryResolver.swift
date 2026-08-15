import Foundation

protocol AgentBinaryResolving: Sendable {
    func resolve(_ agent: AgentKind) throws -> String
}

/// Resolved fresh on every launch action (never cached): the codex binary
/// drifts with ChatGPT.app updates, and claude moves across version switches.
/// Order: settings override → known install locations → common bin dirs →
/// the app process's PATH. Resolution only inspects the filesystem; copying a
/// command must never start a helper shell or any other subprocess.
struct AgentBinaryResolver: AgentBinaryResolving {
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

    init(
        overridePath: @escaping @Sendable (AgentKind) -> String? = Self.configuredOverride,
        homeDirectory: String = NSHomeDirectory(),
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        executableCheck: @escaping @Sendable (String) -> Bool = Self.isExecutable
    ) {
        self.overridePath = overridePath
        self.homeDirectory = homeDirectory
        self.searchPath = searchPath
        self.executableCheck = executableCheck
    }

    func resolve(_ agent: AgentKind) throws -> String {
        var tried: [String] = []

        let override = overridePath(agent)
        if let override {
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

        throw NotFoundError(agent: agent, tried: tried)
    }

    private static func configuredOverride(_ agent: AgentKind) -> String? {
        agent == .codex ? SpotionSettings.codexPathOverride : SpotionSettings.claudePathOverride
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
