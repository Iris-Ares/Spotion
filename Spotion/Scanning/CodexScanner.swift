import Foundation

/// ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
///
/// Line 1 is always session_meta (its payload can carry tens of KB of
/// base_instructions, hence the expandable head window).
/// The first real user input is the first event with type=="event_msg" and
/// payload.type=="user_message" → payload.message; response_item records with
/// role=="user" are context injection and must not be used for titles.
/// Titles are not in the session file — they live in
/// ~/.codex/session_index.jsonl ({id, thread_name, updated_at}).
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
            return []  // root missing: a legitimate empty result
        }

        // Any listing error mid-walk marks the whole result untrustworthy (nil),
        // so partial results are never mistaken for deleted files.
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

    /// The session_meta line can carry giant base_instructions; the window
    /// expands on demand when a fixed window would truncate it.
    private static let maxHeadCap = 4 * 1024 * 1024

    func parse(_ file: ScannedFile) -> SessionRecord? {
        var cap = 512 * 1024
        var best: SessionRecord?
        while true {
            best = parse(file, headCap: cap)
            // Keep expanding while either meta or firstPrompt is missing: a
            // giant injected line (response_item etc.) can push session_meta or
            // the first user_message past the current window. At the 4MB cap /
            // file end, accept what we have (no prompt → project-name title).
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

    /// rollout-2026-08-05T14-16-25-<uuid>.jsonl → last 36 characters of the stem.
    static func uuid(fromFilename path: String) -> String? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return candidate.contains("-") ? candidate : nil
    }

    /// The ~56KB title index; later lines overwrite earlier ones (the same id
    /// is updated repeatedly).
    /// nil = the file exists but reading failed (the caller should keep its
    /// cached titles and skip the title diff this cycle);
    /// [:] = the index file does not exist — titles were legitimately cleared,
    /// the diff proceeds.
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
