import Foundation

enum SessionAliasError: LocalizedError, Equatable {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty: "Alias must contain at least one visible character."
        }
    }
}

/// Spotion-only display aliases. Independent of the scan cache so migrations
/// and rebuilds preserve user-authored names. Fails open: an unreadable file
/// yields no aliases plus a visible warning, and the next successful write
/// replaces the damaged data.
struct SessionAliasStore: Sendable {
    private let file: PersistedJSON<[String: String]>
    private(set) var aliases: [String: String] = [:]
    private(set) var loadWarning: String?

    init(url: URL) {
        file = PersistedJSON(url: url, version: 1)
    }

    mutating func bootstrap() {
        aliases = [:]
        loadWarning = nil
        switch file.load() {
        case .empty:
            break
        case .loaded(let stored), .recovered(let stored):
            aliases = stored
        case .unreadable:
            loadWarning = "Spotion could not read local session aliases because their storage is corrupted. No aliases were applied; setting a new alias will replace the damaged data."
        }
    }

    func alias(for id: String) -> String? {
        aliases[id]
    }

    /// Returns false for an idempotent request. The normalized alias is
    /// whitespace-folded and bounded by the same 100-character title policy
    /// used elsewhere in Spotion.
    @discardableResult
    mutating func setAlias(_ rawAlias: String, for id: String) throws -> Bool {
        let normalized = rawAlias.titleSanitized
        guard !normalized.isEmpty else { throw SessionAliasError.empty }
        guard aliases[id] != normalized else { return false }
        var updated = aliases
        updated[id] = normalized
        try commit(updated)
        return true
    }

    @discardableResult
    mutating func clearAlias(for id: String) throws -> Bool {
        guard aliases[id] != nil else { return false }
        var updated = aliases
        updated.removeValue(forKey: id)
        try commit(updated)
        return true
    }

    @discardableResult
    mutating func prune(validIDs: Set<String>) throws -> Bool {
        let updated = aliases.filter { validIDs.contains($0.key) }
        guard updated != aliases else { return false }
        try commit(updated)
        return true
    }

    /// In-memory state changes only after the atomic write succeeds.
    private mutating func commit(_ updated: [String: String]) throws {
        try file.write(updated)
        aliases = updated
        loadWarning = nil
    }
}
