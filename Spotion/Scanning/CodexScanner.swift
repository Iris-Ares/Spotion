import Foundation

/// ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
///
/// 首行必为 session_meta（payload 可含几十 KB 的 base_instructions，head 上限 512KB）。
/// 首个真实用户输入 = 首条 type=="event_msg" 且 payload.type=="user_message" 的 payload.message；
/// response_item/role=="user" 是上下文注入，不可用作标题。
/// 标题不在会话文件里，而在 ~/.codex/session_index.jsonl（{id, thread_name, updated_at}）。
struct CodexScanner: SessionScanner {
    let agent: AgentKind = .codex
    let sessionsRoot: URL
    let indexURL: URL

    var rootPath: String { sessionsRoot.path }

    init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.sessionsRoot = codexHome.appendingPathComponent("sessions")
        self.indexURL = codexHome.appendingPathComponent("session_index.jsonl")
    }

    func enumerateFiles() -> [ScannedFile]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []  // 根目录不存在：合法的空结果
        }

        // 途中任何列举错误都视为整体不可信（nil），避免部分结果被当作"文件已删除"
        nonisolated(unsafe) var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                failed = true
                return false
            }
        ) else { return nil }

        var out: [ScannedFile] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            if let file = statted(url) { out.append(file) }
        }
        return failed ? nil : out
    }

    private struct Probe: Decodable { var type: String? }

    private struct MetaLine: Decodable {
        struct Payload: Decodable {
            var session_id: String?
            var id: String?
            var cwd: String?
            var timestamp: String?
        }
        var payload: Payload
    }

    private struct EventLine: Decodable {
        struct Payload: Decodable {
            var type: String?
            var message: String?
        }
        var payload: Payload
    }

    /// session_meta 行可含巨型 base_instructions；固定窗口截断时按需扩展。
    private static let maxHeadCap = 4 * 1024 * 1024

    func parse(_ file: ScannedFile) -> SessionRecord? {
        var cap = 512 * 1024
        var best: SessionRecord?
        while true {
            best = parse(file, headCap: cap)
            // meta 与 firstPrompt 任一缺失都继续扩窗：巨型注入行（response_item 等）
            // 可能把 session_meta 或首条 user_message 推到窗口之外。
            // 到达 4MB 上限/文件末尾后接受现状（无 prompt 则回退项目名标题）。
            if let record = best, record.firstPrompt != nil { return record }
            if Int64(cap) >= file.size || cap >= Self.maxHeadCap { return best }
            cap *= 2
        }
    }

    private func parse(_ file: ScannedFile, headCap: Int) -> SessionRecord? {
        guard let lines = try? JSONLReader.headLines(of: URL(fileURLWithPath: file.path), cap: headCap) else {
            return nil
        }
        let decoder = JSONDecoder()
        var meta: MetaLine.Payload?
        var firstPrompt: String?

        for data in lines {
            guard let probe = try? decoder.decode(Probe.self, from: data), let type = probe.type else { continue }
            switch type {
            case "session_meta" where meta == nil:
                meta = (try? decoder.decode(MetaLine.self, from: data))?.payload
            case "event_msg" where firstPrompt == nil:
                guard let event = try? decoder.decode(EventLine.self, from: data),
                      event.payload.type == "user_message",
                      let message = event.payload.message,
                      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                firstPrompt = String(message.prefix(300))
            default:
                continue
            }
            if meta != nil, firstPrompt != nil { break }
        }

        guard let meta else { return nil }
        let sessionID = meta.session_id ?? meta.id ?? Self.uuid(fromFilename: file.path) ?? ""
        guard !sessionID.isEmpty else { return nil }

        let cwd = meta.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        return SessionRecord(
            id: SessionRecord.makeID(agent: .codex, sessionID: sessionID),
            agent: .codex,
            sessionID: sessionID,
            fallbackTitle: nil,
            firstPrompt: firstPrompt,
            cwd: cwd,
            projectName: (cwd as NSString).lastPathComponent,
            gitBranch: nil,
            startedAt: meta.timestamp.flatMap(ISO8601.date(from:)),
            lastActivityAt: file.mtime,
            filePath: file.path,
            fileSize: file.size
        )
    }

    /// rollout-2026-08-05T14-16-25-<uuid>.jsonl → 取末尾 36 字符
    static func uuid(fromFilename path: String) -> String? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return candidate.contains("-") ? candidate : nil
    }

    /// 56KB 量级的标题索引，后出现的行覆盖先出现的（同 id 多次更新）。
    /// 返回 nil = 文件存在但读取失败（调用方应保留旧标题，本轮不做标题 diff）；
    /// 返回 [:] = 索引文件不存在——标题被合法清除，diff 照常。
    func loadTitleIndex() -> [String: String]? {
        struct Entry: Decodable {
            var id: String?
            var thread_name: String?
        }
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [:] }
        guard let lines = try? JSONLReader.headLines(of: indexURL, cap: 8 * 1024 * 1024) else { return nil }
        let decoder = JSONDecoder()
        var titles: [String: String] = [:]
        for data in lines {
            guard let entry = try? decoder.decode(Entry.self, from: data),
                  let id = entry.id,
                  let name = entry.thread_name,
                  !name.isEmpty else { continue }
            titles[id] = name
        }
        return titles
    }
}
