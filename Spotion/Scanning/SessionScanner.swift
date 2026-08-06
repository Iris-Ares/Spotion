import Foundation

struct ScannedFile: Sendable, Hashable {
    var path: String
    var mtime: Date
    var size: Int64
}

enum ParseOutcome: Sendable {
    case record(SessionRecord)
    /// Transcript was read but is unusable (no session_meta / no cwd …):
    /// cached as nil and not retried until the file changes.
    case unusable
    /// The content read itself failed (open/read error). Must NOT be cached —
    /// the stale mtime/size in the existing entry guarantees a retry on the
    /// next refresh once the file is readable again.
    case ioFailure

    var record: SessionRecord? {
        if case .record(let record) = self { return record }
        return nil
    }
}

protocol SessionScanner: Sendable {
    var agent: AgentKind { get }
    /// Scan root (used to attribute cache entries during the deletion diff).
    var rootPath: String { get }
    /// Stat only, no content reads.
    /// nil = enumeration failed (permission blip etc.) → the caller must not
    /// delete anything under this root this cycle;
    /// [] = root empty or missing → a legitimate result, deletions proceed.
    func enumerateFiles() -> [ScannedFile]?
    /// Bounded-read parse; see ParseOutcome for the tri-state semantics.
    func parse(_ file: ScannedFile) -> ParseOutcome
}

extension SessionScanner {
    func statted(_ url: URL) -> ScannedFile? {
        guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = rv.contentModificationDate,
              let size = rv.fileSize else { return nil }
        return ScannedFile(path: url.path, mtime: mtime, size: Int64(size))
    }
}
