import Foundation

enum SessionAliasError: LocalizedError, Equatable {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty: "Alias must contain at least one visible character."
        }
    }
}

/// Versioned persistence for Spotion-only display aliases. It is deliberately
/// separate from the scan cache so cache migrations and rebuilds preserve
/// user-authored names.
struct SessionAliasStore: Sendable {
    private struct Payload: Codable {
        static let currentVersion = 1

        var version = currentVersion
        var aliases: [String: String]
    }

    let url: URL
    private(set) var aliases: [String: String] = [:]
    private(set) var loadWarning: String?

    mutating func bootstrap() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            aliases = [:]
            loadWarning = nil
            return
        }
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Payload.currentVersion else {
            aliases = [:]
            loadWarning = "Spotion could not read local session aliases because their storage is corrupted. No aliases were applied; setting a new alias will replace the damaged data."
            return
        }
        aliases = payload.aliases
        loadWarning = nil
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
        try persist(updated)
        aliases = updated
        loadWarning = nil
        return true
    }

    @discardableResult
    mutating func clearAlias(for id: String) throws -> Bool {
        guard aliases[id] != nil else { return false }
        var updated = aliases
        updated.removeValue(forKey: id)
        try persist(updated)
        aliases = updated
        loadWarning = nil
        return true
    }

    @discardableResult
    mutating func prune(validIDs: Set<String>) throws -> Bool {
        let updated = aliases.filter { validIDs.contains($0.key) }
        guard updated != aliases else { return false }
        try persist(updated)
        aliases = updated
        loadWarning = nil
        return true
    }

    private func persist(_ updated: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Payload(aliases: updated))
        try data.write(to: url, options: .atomic)
    }
}

/// Pure keyword construction shared by Core Spotlight and hostless tests.
/// Case-insensitive de-duplication prevents an alias identical to the source
/// title from adding redundant metadata while preserving stable order.
enum SessionSearchMetadata {
    static func keywords(
        displayTitle: String,
        sourceTitle: String?,
        projectName: String,
        agent: AgentKind,
        gitBranch: String?,
        cwd: String
    ) -> [String] {
        var candidates = [displayTitle]
        if let sourceTitle { candidates.append(sourceTitle) }
        candidates += [projectName, agent.displayName, agent.rawValue, "session"]
        if let gitBranch { candidates.append(gitBranch) }
        candidates += cwd.split(separator: "/").map(String.init)

        var seen = Set<String>()
        return candidates.filter {
            let key = $0.lowercased()
            return !$0.isEmpty && seen.insert(key).inserted
        }
    }
}
