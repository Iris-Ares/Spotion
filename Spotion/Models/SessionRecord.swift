import Foundation

enum CodexSessionProvenance: String, Codable, Sendable, Hashable {
    case topLevel
    case subagent
    /// Missing legacy metadata is top-level; present but unsupported or
    /// malformed metadata is unrecognized and deliberately remains visible.
    case unrecognized
}

struct SessionRecord: Codable, Sendable, Identifiable, Hashable {
    /// Stable Spotlight identifier: "codex:<uuid>" / "claude:<uuid>"
    var id: String
    var agent: AgentKind
    /// Raw session id passed to `codex resume` / `claude --resume`
    var sessionID: String
    /// claude: title parsed from the tail title records; always nil for codex
    /// (codex titles live in session_index.jsonl)
    var fallbackTitle: String?
    /// First real user input (truncated to ~300 characters). Confirmed Codex
    /// children keep this nil because their leading history may be inherited.
    var firstPrompt: String?
    /// Opt-in, bounded snippets from the most recent later user turns. This is
    /// transient runtime state: CodingKeys deliberately omit it so prompt text
    /// is donated to Spotlight without entering Spotion's persisted scan cache.
    var laterPromptSnippets: [String]
    /// Opt-in, bounded project-relative paths extracted only from allowlisted
    /// structured file-tool inputs. Like later prompts these are transient and
    /// deliberately omitted from CodingKeys.
    var touchedFilePaths: [String]
    /// The explicit source cwd used to normalize tool paths. This remains nil
    /// when Codex metadata omitted cwd, preventing a fallback home directory
    /// from being mistaken for trustworthy project provenance.
    var touchedFileBasePath: String?
    /// Transient proof that this in-memory record was parsed with the current
    /// touched-file extraction generation, even when no eligible path existed.
    var touchedFileHydrationGeneration: Int
    /// True only while this record is authoritative from Codex's documented
    /// archived_sessions root. Persisted so a relaunch never presents an
    /// archived result as immediately resumable.
    var isArchived: Bool
    /// Compact, source-derived Codex classification. Claude records are always
    /// top-level because Claude's nested subagent files are excluded by its
    /// scanner's depth-bounded enumeration.
    var codexProvenance: CodexSessionProvenance
    /// Present only when a recognized Codex thread-spawn source supplies it.
    var parentSessionID: String?
    var cwd: String
    var projectName: String
    var gitBranch: String?
    var startedAt: Date?
    /// File mtime
    var lastActivityAt: Date
    var filePath: String
    var fileSize: Int64

    private enum CodingKeys: String, CodingKey {
        case id, agent, sessionID, fallbackTitle, firstPrompt, isArchived, codexProvenance, parentSessionID
        case cwd, projectName
        case gitBranch, startedAt, lastActivityAt, filePath, fileSize
    }

    init(
        id: String,
        agent: AgentKind,
        sessionID: String,
        fallbackTitle: String?,
        firstPrompt: String?,
        laterPromptSnippets: [String],
        touchedFilePaths: [String] = [],
        touchedFileBasePath: String? = nil,
        touchedFileHydrationGeneration: Int = 0,
        isArchived: Bool = false,
        codexProvenance: CodexSessionProvenance = .topLevel,
        parentSessionID: String? = nil,
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
        self.touchedFilePaths = touchedFilePaths
        self.touchedFileBasePath = touchedFileBasePath
        self.touchedFileHydrationGeneration = touchedFileHydrationGeneration
        self.isArchived = isArchived
        self.codexProvenance = codexProvenance
        self.parentSessionID = parentSessionID
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
        touchedFilePaths = []
        touchedFileBasePath = nil
        touchedFileHydrationGeneration = 0
        // Valid pre-feature v6 caches contain active sessions only.
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        codexProvenance = try values.decodeIfPresent(
            CodexSessionProvenance.self, forKey: .codexProvenance) ?? .topLevel
        parentSessionID = try values.decodeIfPresent(String.self, forKey: .parentSessionID)
        if codexProvenance == .subagent { firstPrompt = nil }
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
        if codexProvenance != .subagent {
            try values.encodeIfPresent(firstPrompt, forKey: .firstPrompt)
        }
        try values.encode(isArchived, forKey: .isArchived)
        try values.encode(codexProvenance, forKey: .codexProvenance)
        try values.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
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

    func spotlightKeywords(sourceTitle: String? = nil, includeTouchedFiles: Bool = false) -> [String] {
        Self.spotlightKeywords(
            projectName: projectName,
            agent: agent,
            sessionID: sessionID,
            id: id,
            gitBranch: gitBranch,
            cwd: cwd,
            sourceTitle: sourceTitle,
            touchedFilePaths: touchedFilePaths,
            includeTouchedFiles: includeTouchedFiles
        )
    }

    static func spotlightKeywords(
        projectName: String,
        agent: AgentKind,
        sessionID: String,
        id: String,
        gitBranch: String?,
        cwd: String,
        sourceTitle: String? = nil,
        touchedFilePaths: [String] = [],
        includeTouchedFiles: Bool = false,
        isArchived: Bool = false
    ) -> [String] {
        // The agent-derived title stays searchable when a Spotion alias
        // replaces the visible title.
        var candidates = [projectName, agent.displayName, agent.rawValue, "session"]
        if let sourceTitle { candidates.append(sourceTitle) }
        if let gitBranch { candidates.append(gitBranch) }
        candidates += cwd.split(separator: "/").map(String.init)
        candidates += [sessionID, id]
        if isArchived { candidates.append("archived") }
        if includeTouchedFiles {
            for path in touchedFilePaths {
                candidates.append(path)
                candidates.append((path as NSString).lastPathComponent)
            }
        }

        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func spotlightContentDescription(
        includeLaterPrompts: Bool,
        sourceTitle: String? = nil,
        includeTouchedFiles: Bool = false
    ) -> String {
        Self.spotlightContentDescription(
            firstPrompt: firstPrompt,
            laterPrompts: laterPromptSnippets,
            cwd: cwd,
            includeLaterPrompts: includeLaterPrompts,
            gitBranch: gitBranch,
            sourceTitle: sourceTitle,
            isArchived: isArchived,
            isSubagent: codexProvenance == .subagent,
            touchedFilePaths: includeTouchedFiles ? touchedFilePaths : []
        )
    }

    /// The Spotlight *UI* on macOS 26 matches app-entity results against the
    /// title and this description only — `keywords` are honoured by
    /// CSUserQuery but not by the typed-query UI. Everything a user should be
    /// able to type to find a session therefore has to appear here as well.
    /// Session IDs are deliberately left out: they stay keyword-only so the
    /// visible snippet never shows raw identifiers.
    static func spotlightContentDescription(
        firstPrompt: String?,
        laterPrompts: [String],
        cwd: String,
        includeLaterPrompts: Bool,
        gitBranch: String? = nil,
        sourceTitle: String? = nil,
        isArchived: Bool = false,
        isSubagent: Bool = false,
        touchedFilePaths: [String] = []
    ) -> String {
        var parts = [firstPrompt]
        if includeLaterPrompts { parts.append(contentsOf: laterPrompts.map(Optional.some)) }
        parts.append(cwd)
        var metadata: [String] = []
        if isArchived { metadata.append("Archived") }
        if isSubagent { metadata.append("Subagent") }
        if let gitBranch, !gitBranch.isEmpty { metadata.append(gitBranch) }
        if let sourceTitle, !sourceTitle.isEmpty { metadata.append(sourceTitle) }
        if !metadata.isEmpty { parts.append(metadata.joined(separator: " · ")) }
        if !touchedFilePaths.isEmpty { parts.append(touchedFilePaths.joined(separator: " ")) }
        return parts.compactMap { $0 }.joined(separator: "\n")
    }
}

enum TouchedFilePolicy {
    /// Bump when allowlisted schemas or normalization semantics change. The
    /// store persists this generation and rehydrates unchanged transcripts
    /// once while the preference is enabled.
    static let extractionGeneration = 1
    static let tailReadCap = 512 * 1024
    static let maximumCount = 20
    static let maximumDonatedLength = 2_000

    /// Lexically normalize an explicit tool path into a project-relative path.
    /// No project file is opened, statted, crawled, or symlink-resolved.
    static func normalize(
        _ rawPath: String,
        relativeTo cwd: String,
        caseSensitive: Bool
    ) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasSuffix("/"),
              !trimmed.hasSuffix("\\"),
              !trimmed.hasPrefix("~"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        let base = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
        guard base.hasPrefix("/") else { return nil }
        let absolute: String
        if trimmed.hasPrefix("/") {
            absolute = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        } else {
            absolute = URL(fileURLWithPath: trimmed, relativeTo: URL(fileURLWithPath: base, isDirectory: true))
                .standardizedFileURL.path
        }

        let comparisonBase = caseSensitive ? base : base.lowercased()
        let comparisonPath = caseSensitive ? absolute : absolute.lowercased()
        let prefix = comparisonBase == "/" ? "/" : comparisonBase + "/"
        guard comparisonPath.hasPrefix(prefix), comparisonPath != comparisonBase else { return nil }

        let relativeStart = absolute.index(absolute.startIndex, offsetBy: base == "/" ? 1 : base.count + 1)
        let relative = String(absolute[relativeStart...])
        guard !relative.isEmpty,
              relative != ".",
              (relative as NSString).lastPathComponent != ".",
              (relative as NSString).lastPathComponent != ".."
        else { return nil }
        return relative
    }

    /// Inputs are chronological; output is newest-first with the newest
    /// spelling winning case-insensitive duplicates.
    static func mostRecent(
        _ rawPaths: [String],
        relativeTo cwd: String,
        caseSensitive: Bool
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var donatedLength = 0

        for rawPath in rawPaths.reversed() {
            guard result.count < maximumCount,
                  let relative = normalize(rawPath, relativeTo: cwd, caseSensitive: caseSensitive)
            else { continue }
            let key = caseSensitive ? relative : relative.lowercased()
            guard seen.insert(key).inserted else { continue }
            let basename = (relative as NSString).lastPathComponent
            let contribution = relative.count + (basename == relative ? 0 : 1 + basename.count)
            let separator = result.isEmpty ? 0 : 1
            guard donatedLength + separator + contribution <= maximumDonatedLength else { continue }
            result.append(relative)
            donatedLength += separator + contribution
        }
        return result
    }

    static func volumeIsCaseSensitive(at path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? true
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
