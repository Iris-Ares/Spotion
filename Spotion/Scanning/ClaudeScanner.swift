import Foundation

/// ~/.claude/projects/<escaped-cwd>/<session-uuid>.jsonl
///
/// 目录名转义不可逆，cwd 必须从记录 envelope 读取；首行可能是无 envelope 的 queue-operation。
/// 子 agent 转录嵌套在 <uuid>/subagents/ 下，按"仅深度 2"枚举天然排除。
/// 标题在文件尾部的紧凑记录里（会被反复重写，取各自最后一条）：
///   custom-title > ai-title > last-prompt > 首条非 sidechain 用户消息。
/// 官方声明该格式随版本变化 → 全部防御式解析。
struct ClaudeScanner: SessionScanner {
    let agent: AgentKind = .claude
    let projectsRoot: URL

    var rootPath: String { projectsRoot.path }

    init(claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.projectsRoot = claudeHome.appendingPathComponent("projects")
    }

    func enumerateFiles() -> [ScannedFile] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [ScannedFile] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
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
        // 尾部紧凑标题记录
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
    }

    /// 头窗口按需扩展：首条含 cwd 的记录可能是一条数百 KB 的巨型粘贴内容行，
    /// 固定窗口会把它当作不完整行丢弃，导致整个会话被误判为不可用。
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

        // 无 cwd 就无法 resume（claude --resume 按进程 cwd 查找会话），视为不可用
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

    /// 排除斜杠命令包装（<command-name>…）与 Claude Code 注入的 caveat 说明
    static func looksLikeRealPrompt(_ text: String) -> Bool {
        !text.hasPrefix("<") && !text.hasPrefix("Caveat:")
    }

    /// 尾部 64KB 起步、找不到任何标题记录则倍增扩窗到 512KB。
    private static func scanTailTitles(url: URL, fileSize: Int64) -> (custom: String?, ai: String?, lastPrompt: String?) {
        let decoder = JSONDecoder()
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
            if custom != nil || ai != nil || lastPrompt != nil { return (custom, ai, lastPrompt) }
            if Int64(cap) >= fileSize || cap >= 512 * 1024 { return (nil, nil, nil) }
            cap *= 2
        }
    }
}
