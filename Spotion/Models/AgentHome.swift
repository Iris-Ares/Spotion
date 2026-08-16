import Foundation

enum AgentHomePathPolicy {
    static func defaultPath(for agent: AgentKind) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(agent == .codex ? ".codex" : ".claude", isDirectory: true)
            .standardizedFileURL.path
    }

    static func normalize(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        let canonical = try? standardized
            .resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        return canonical.flatMap { $0.isEmpty ? nil : $0 } ?? standardized.path
    }

    static func additionalPaths(_ rawPaths: [String], for agent: AgentKind) -> [String] {
        let defaultPath = defaultPath(for: agent)
        let defaultKey = comparisonKey(defaultPath)
        var seen = Set<String>()
        return rawPaths.compactMap(normalize).filter {
            comparisonKey($0) != defaultKey && seen.insert(comparisonKey($0)).inserted
        }
    }

    static func comparisonKey(_ path: String) -> String {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let isCaseSensitive = try? url.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames
        return isCaseSensitive == false ? path.lowercased() : path
    }

    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

enum NativeAppSourcePolicy {
    static func unsupportedReason(for record: SessionRecord) -> String? {
        guard !record.isDefaultAgentHome else { return nil }
        return "该会话来自额外的 \(record.agent.displayName) Home（\(AgentHomePathPolicy.displayPath(record.agentHomePath))），桌面应用无法可靠指定此来源。请在 Spotion 设置里把该来源的打开方式改为终端 CLI。"
    }
}

extension AgentKind {
    var homeEnvironmentVariable: String {
        switch self {
        case .codex: "CODEX_HOME"
        case .claude: "CLAUDE_CONFIG_DIR"
        }
    }
}
