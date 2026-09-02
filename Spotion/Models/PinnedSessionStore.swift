import Foundation

/// User-selected pins. Independent of the scan cache so a cache migration or
/// rebuild cannot erase them. Fails open: pins affect ranking and convenience,
/// not privacy, so an unreadable file recovers to "no pins" rather than
/// pausing the index.
struct PinnedSessionStore: Sendable {
    private let file: PersistedJSON<[String]>
    private(set) var sessionIDs: Set<String> = []
    private(set) var recoveredFromCorruption = false

    init(url: URL) {
        file = PersistedJSON(url: url, version: 1)
    }

    mutating func bootstrap() {
        switch file.load() {
        case .empty:
            sessionIDs = []
            recoveredFromCorruption = false
        case .loaded(let ids), .recovered(let ids):
            sessionIDs = Set(ids)
            recoveredFromCorruption = false
        case .unreadable:
            // Recovering to an empty set is safer than inventing pins; the
            // next successful pin operation replaces the corrupt payload.
            sessionIDs = []
            recoveredFromCorruption = true
        }
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
        try file.write(updated.sorted())
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
        try file.write(updated.sorted())
        sessionIDs = updated
        recoveredFromCorruption = false
        return true
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
