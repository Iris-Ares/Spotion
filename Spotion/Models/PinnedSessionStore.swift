import Foundation

/// Small, independent persistence boundary for user-selected pins. Pins live
/// outside the scan cache so a cache migration or rebuild cannot erase them.
struct PinnedSessionStore: Sendable {
    private struct Payload: Codable {
        static let currentVersion = 1

        var version = currentVersion
        var sessionIDs: [String]
    }

    let url: URL
    private(set) var sessionIDs: Set<String> = []
    private(set) var recoveredFromCorruption = false

    mutating func bootstrap() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            sessionIDs = []
            recoveredFromCorruption = false
            return
        }
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Payload.currentVersion else {
            // Pins affect ranking and convenience, not transcript ownership or
            // privacy. Recovering to an empty set is safer than inventing pins;
            // the next successful pin operation replaces the corrupt payload.
            sessionIDs = []
            recoveredFromCorruption = true
            return
        }
        sessionIDs = Set(payload.sessionIDs)
        recoveredFromCorruption = false
    }

    func contains(_ id: String) -> Bool {
        sessionIDs.contains(id)
    }

    /// Returns false for an idempotent request. The in-memory state changes
    /// only after the atomic write succeeds.
    @discardableResult
    mutating func setPinned(_ pinned: Bool, id: String) throws -> Bool {
        var updated = sessionIDs
        if pinned {
            updated.insert(id)
        } else {
            updated.remove(id)
        }
        guard updated != sessionIDs else { return false }
        try persist(updated)
        sessionIDs = updated
        recoveredFromCorruption = false
        return true
    }

    /// Removes pins whose source session no longer exists. Persistence failure
    /// leaves the old in-memory set intact so a later refresh can retry.
    @discardableResult
    mutating func prune(validIDs: Set<String>) throws -> Bool {
        let updated = sessionIDs.intersection(validIDs)
        guard updated != sessionIDs else { return false }
        try persist(updated)
        sessionIDs = updated
        recoveredFromCorruption = false
        return true
    }

    private func persist(_ ids: Set<String>) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Payload(sessionIDs: ids.sorted())
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }
}

/// Pure mapping kept in the hostless test target. Core Spotlight treats this
/// as a relative hint; it does not guarantee ordering against other apps.
enum SessionDonationPriority {
    static let standard = 0
    static let pinned = 10

    static func value(isPinned: Bool) -> Int {
        isPinned ? pinned : standard
    }
}
