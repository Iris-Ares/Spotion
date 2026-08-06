import Foundation

struct ScannedFile: Sendable, Hashable {
    var path: String
    var mtime: Date
    var size: Int64
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
    /// Bounded-read parse; returns nil when unusable (counted as a failure,
    /// not retried until the file changes).
    func parse(_ file: ScannedFile) -> SessionRecord?
}

extension SessionScanner {
    func statted(_ url: URL) -> ScannedFile? {
        guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = rv.contentModificationDate,
              let size = rv.fileSize else { return nil }
        return ScannedFile(path: url.path, mtime: mtime, size: Int64(size))
    }
}
