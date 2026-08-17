import Foundation

struct SessionRecord: Codable, Sendable, Identifiable, Hashable {
    /// Stable Spotlight identifier: "codex:<uuid>" / "claude:<uuid>"
    var id: String
    var agent: AgentKind
    /// Raw session id passed to `codex resume` / `claude --resume`
    var sessionID: String
    /// claude: title parsed from the tail title records; always nil for codex
    /// (codex titles live in session_index.jsonl)
    var fallbackTitle: String?
    /// First real user input (truncated to ~300 characters)
    var firstPrompt: String?
    /// Opt-in, bounded snippets from the most recent later user turns. This is
    /// transient runtime state: CodingKeys deliberately omit it so prompt text
    /// is donated to Spotlight without entering Spotion's persisted scan cache.
    var laterPromptSnippets: [String]
    /// True only while this record is authoritative from Codex's documented
    /// archived_sessions root. Persisted so a relaunch never presents an
    /// archived result as immediately resumable.
    var isArchived: Bool
    var cwd: String
    var projectName: String
    var gitBranch: String?
    var startedAt: Date?
    /// File mtime
    var lastActivityAt: Date
    var filePath: String
    var fileSize: Int64

    private enum CodingKeys: String, CodingKey {
        case id, agent, sessionID, fallbackTitle, firstPrompt, isArchived, cwd, projectName
        case gitBranch, startedAt, lastActivityAt, filePath, fileSize
    }

    init(
        id: String,
        agent: AgentKind,
        sessionID: String,
        fallbackTitle: String?,
        firstPrompt: String?,
        laterPromptSnippets: [String],
        isArchived: Bool = false,
        cwd: String,
        projectName: String,
        gitBranch: String?,
        startedAt: Date?,
        lastActivityAt: Date,
        filePath: String,
        fileSize: Int64
    ) {
        self.id = id
        self.agent = agent
        self.sessionID = sessionID
        self.fallbackTitle = fallbackTitle
        self.firstPrompt = firstPrompt
        self.laterPromptSnippets = laterPromptSnippets
        self.isArchived = isArchived
        self.cwd = cwd
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.filePath = filePath
        self.fileSize = fileSize
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        agent = try values.decode(AgentKind.self, forKey: .agent)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        fallbackTitle = try values.decodeIfPresent(String.self, forKey: .fallbackTitle)
        firstPrompt = try values.decodeIfPresent(String.self, forKey: .firstPrompt)
        laterPromptSnippets = []
        // Valid pre-feature v6 caches contain active sessions only.
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        cwd = try values.decode(String.self, forKey: .cwd)
        projectName = try values.decode(String.self, forKey: .projectName)
        gitBranch = try values.decodeIfPresent(String.self, forKey: .gitBranch)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        lastActivityAt = try values.decode(Date.self, forKey: .lastActivityAt)
        filePath = try values.decode(String.self, forKey: .filePath)
        fileSize = try values.decode(Int64.self, forKey: .fileSize)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(agent, forKey: .agent)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encodeIfPresent(fallbackTitle, forKey: .fallbackTitle)
        try values.encodeIfPresent(firstPrompt, forKey: .firstPrompt)
        try values.encode(isArchived, forKey: .isArchived)
        try values.encode(cwd, forKey: .cwd)
        try values.encode(projectName, forKey: .projectName)
        try values.encodeIfPresent(gitBranch, forKey: .gitBranch)
        try values.encodeIfPresent(startedAt, forKey: .startedAt)
        try values.encode(lastActivityAt, forKey: .lastActivityAt)
        try values.encode(filePath, forKey: .filePath)
        try values.encode(fileSize, forKey: .fileSize)
    }

    static func makeID(agent: AgentKind, sessionID: String) -> String {
        "\(agent.rawValue):\(sessionID)"
    }

    func spotlightContentDescription(includeLaterPrompts: Bool) -> String {
        Self.spotlightContentDescription(
            firstPrompt: firstPrompt,
            laterPrompts: laterPromptSnippets,
            cwd: cwd,
            includeLaterPrompts: includeLaterPrompts
        )
    }

    static func spotlightContentDescription(
        firstPrompt: String?,
        laterPrompts: [String],
        cwd: String,
        includeLaterPrompts: Bool
    ) -> String {
        var parts = [firstPrompt]
        if includeLaterPrompts { parts.append(contentsOf: laterPrompts.map(Optional.some)) }
        parts.append(cwd)
        return parts.compactMap { $0 }.joined(separator: "\n")
    }
}

enum PromptSnippetPolicy {
    static let tailReadCap = 512 * 1024
    static let maximumCount = 5
    static let maximumSnippetLength = 300
    static let maximumAggregateLength = 1_500

    static func isRealPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("<") && !trimmed.hasPrefix("Caveat:")
    }

    /// Returns newest-first snippets. The aggregate budget includes newline
    /// separators exactly as donated to Spotlight.
    static func mostRecent(_ prompts: [String], excluding firstPrompt: String?) -> [String] {
        let excluded = firstPrompt.flatMap(sanitize)
        var seen = Set<String>()
        if let excluded { seen.insert(excluded) }
        var result: [String] = []
        var donatedLength = 0

        for prompt in prompts.reversed() {
            guard result.count < maximumCount, let snippet = sanitize(prompt), seen.insert(snippet).inserted else {
                continue
            }
            let separatorLength = result.isEmpty ? 0 : 1
            let remaining = maximumAggregateLength - donatedLength - separatorLength
            guard remaining > 0 else { break }
            let bounded = String(snippet.prefix(remaining))
            guard !bounded.isEmpty else { break }
            result.append(bounded)
            donatedLength += separatorLength + bounded.count
        }
        return result
    }

    private static func sanitize(_ text: String) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumSnippetLength))
    }
}

extension String {
    /// Collapsed to a single line, whitespace-folded and truncated — used as
    /// the Spotlight title.
    var titleSanitized: String {
        let collapsed = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(100))
    }
}
