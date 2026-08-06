import Foundation

/// ~/.claude/projects/<escaped-cwd>/<session-uuid>.jsonl
///
/// The directory-name escaping is lossy, so cwd must be read from record
/// envelopes; the first line may be a queue-operation with no envelope.
/// Subagent transcripts are nested under <uuid>/subagents/ and are excluded
/// structurally by enumerating at depth 2 only.
/// Titles live in compact records near the file tail (rewritten repeatedly,
/// take the LAST occurrence of each):
///   custom-title > ai-title > last-prompt > first non-sidechain user message.
/// The format is officially documented as internal and version-unstable →
/// every decode is defensive.
struct ClaudeScanner: SessionScanner {
    let agent: AgentKind = .claude
    let projectsRoot: URL

    var rootPath: String { projectsRoot.path }

    init(claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.projectsRoot = claudeHome.appendingPathComponent("projects")
    }

    func enumerateFiles() -> [ScannedFile]? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: projectsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []  // root missing: a legitimate empty result
        }
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }  // listing failed: untrustworthy, no deletions this cycle

        var out: [ScannedFile] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }  // subdirectory listing failed: partial results would read as deletions
            for url in files where url.pathExtension == "jsonl" {
                if let file = statted(url) { out.append(file) }
            }
        }
        return out
    }

    private struct Envelope: Decodable {
        struct Message: Decodable {
            var role: String?
            var content: Content?
        }

        enum Content: Decodable {
            case text(String)
            case blocks([Block])

            struct Block: Decodable {
                var type: String?
                var text: String?
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let s = try? container.decode(String.self) {
                    self = .text(s)
                } else if let b = try? container.decode([Block].self) {
                    self = .blocks(b)
                } else {
                    self = .text("")
                }
            }

            var plainText: String {
                switch self {
                case .text(let s): s
                case .blocks(let blocks):
                    blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
                }
            }
        }

        var type: String?
        var sessionId: String?
        var cwd: String?
        var gitBranch: String?
        var timestamp: String?
        var isSidechain: Bool?
        var message: Message?
        // compact title records near the tail
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
    }

    /// Head window expands on demand: the first cwd-bearing record can be a
    /// single pasted-content line hundreds of KB long, which a fixed window
    /// would drop as an incomplete line, misclassifying the whole session as
    /// unusable.
    private static let maxHeadCap = 4 * 1024 * 1024

    func parse(_ file: ScannedFile) -> SessionRecord? {
        var cap = 256 * 1024
        while true {
            if let record = parse(file, headCap: cap) { return record }
            if Int64(cap) >= file.size || cap >= Self.maxHeadCap { return nil }
            cap *= 2
        }
    }

    private func parse(_ file: ScannedFile, headCap: Int) -> SessionRecord? {
        let url = URL(fileURLWithPath: file.path)
        guard let head = try? JSONLReader.headLines(of: url, cap: headCap) else { return nil }

        let decoder = JSONDecoder()
        var cwd: String?
        var gitBranch: String?
        var startedAt: Date?
        var firstPrompt: String?

        for data in head {
            guard let e = try? decoder.decode(Envelope.self, from: data) else { continue }
            if cwd == nil, let c = e.cwd, !c.isEmpty { cwd = c }
            if gitBranch == nil, let b = e.gitBranch, !b.isEmpty { gitBranch = b }
            if startedAt == nil, let t = e.timestamp { startedAt = ISO8601.date(from: t) }
            if firstPrompt == nil, e.type == "user", e.isSidechain != true,
               let text = e.message?.content?.plainText.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, Self.looksLikeRealPrompt(text) {
                firstPrompt = String(text.prefix(300))
            }
            if cwd != nil, startedAt != nil, firstPrompt != nil { break }
        }

        // Without a cwd the session cannot be resumed (`claude --resume` looks
        // sessions up by process cwd) — treat as unusable.
        guard let cwd else { return nil }

        let titles = Self.scanTailTitles(url: url, fileSize: file.size)
        let sessionID = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension

        return SessionRecord(
            id: SessionRecord.makeID(agent: .claude, sessionID: sessionID),
            agent: .claude,
            sessionID: sessionID,
            fallbackTitle: titles.custom ?? titles.ai ?? titles.lastPrompt,
            firstPrompt: firstPrompt,
            cwd: cwd,
            projectName: (cwd as NSString).lastPathComponent,
            gitBranch: gitBranch,
            startedAt: startedAt,
            lastActivityAt: file.mtime,
            filePath: file.path,
            fileSize: file.size
        )
    }

    /// Excludes slash-command wrappers (<command-name>…) and the caveat notes
    /// Claude Code injects.
    static func looksLikeRealPrompt(_ text: String) -> Bool {
        !text.hasPrefix("<") && !text.hasPrefix("Caveat:")
    }

    /// Tail scan starting at 64KB, doubling up to 512KB.
    /// Only a custom-title (highest priority) short-circuits the expansion;
    /// with just an ai-title / last-prompt in the window the scan keeps
    /// widening — a higher-priority record may sit slightly earlier, and
    /// returning early would let a window-local last-prompt beat it, violating
    /// the title priority order.
    private static func scanTailTitles(url: URL, fileSize: Int64) -> (custom: String?, ai: String?, lastPrompt: String?) {
        let decoder = JSONDecoder()
        let maxCap = 512 * 1024
        var cap = 64 * 1024
        while true {
            guard let lines = try? JSONLReader.tailLines(of: url, cap: cap) else { return (nil, nil, nil) }
            var custom: String?
            var ai: String?
            var lastPrompt: String?
            for data in lines {
                guard let e = try? decoder.decode(Envelope.self, from: data), let type = e.type else { continue }
                switch type {
                case "custom-title": if let v = e.customTitle, !v.isEmpty { custom = v }
                case "ai-title": if let v = e.aiTitle, !v.isEmpty { ai = v }
                case "last-prompt": if let v = e.lastPrompt, !v.isEmpty { lastPrompt = v }
                default: break
                }
            }
            if custom != nil { return (custom, ai, lastPrompt) }
            if Int64(cap) >= fileSize || cap >= maxCap { return (custom, ai, lastPrompt) }
            cap *= 2
        }
    }
}
