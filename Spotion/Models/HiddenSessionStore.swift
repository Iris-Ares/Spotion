import Foundation

struct HiddenSessionSnapshot: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var agent: AgentKind
    var title: String
    var projectName: String
    var cwd: String
    var filePath: String
}

enum HiddenSessionStoreError: LocalizedError, Sendable {
    case unavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Hidden-session state is unavailable. Spotion indexing remains paused to avoid exposing hidden sessions."
        case .writeFailed(let detail):
            "Hidden-session state could not be saved: \(detail)"
        }
    }
}

/// Spotion-only hide state. Fails closed: if neither the primary nor the
/// mirror can be read, nothing is visible until the user restores the file —
/// exposing a session the user hid is worse than an empty index.
struct HiddenSessionStore: Sendable {
    private let file: PersistedJSON<[String: HiddenSessionSnapshot]>
    private var entries: [String: HiddenSessionSnapshot] = [:]
    private(set) var isAvailable = true
    private(set) var statusMessage: String?

    init(url: URL) {
        file = PersistedJSON(url: url, mirrorURL: url.appendingPathExtension("recovery"), version: 1)
    }

    mutating func load() {
        entries = [:]
        isAvailable = true
        statusMessage = nil
        switch file.load() {
        case .empty:
            break
        case .loaded(let loaded):
            entries = loaded
        case .recovered(let recovered):
            entries = recovered
            statusMessage = "Hidden-session state was recovered from its safety copy."
        case .unreadable:
            isAvailable = false
            statusMessage = HiddenSessionStoreError.unavailable.localizedDescription
        }
    }

    var hiddenIDs: Set<String> { Set(entries.keys) }

    func contains(_ id: String) -> Bool {
        entries[id] != nil
    }

    func allowsVisibility(of id: String) -> Bool {
        isAvailable && entries[id] == nil
    }

    func snapshots() -> [HiddenSessionSnapshot] {
        entries.values.sorted {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
        }
    }

    mutating func hide(_ snapshot: HiddenSessionSnapshot) throws -> Bool {
        try requireAvailable()
        guard entries[snapshot.id] == nil else { return false }
        let previous = entries
        entries[snapshot.id] = snapshot
        try persist(orRestore: previous)
        return true
    }

    mutating func restore(id: String) throws -> Bool {
        try requireAvailable()
        guard entries[id] != nil else { return false }
        let previous = entries
        entries.removeValue(forKey: id)
        try persist(orRestore: previous)
        return true
    }

    /// Prune only agents whose transcript root was enabled and enumerated
    /// successfully. Disabled agents and transient enumeration failures retain
    /// their hide state across future refreshes.
    mutating func pruneMissing(
        validIDs: Set<String>,
        trustworthyAgents: Set<AgentKind>
    ) throws -> [String] {
        try requireAvailable()
        let stale = entries.values.filter {
            trustworthyAgents.contains($0.agent) && !validIDs.contains($0.id)
        }.map(\.id)
        guard !stale.isEmpty else { return [] }

        let previous = entries
        for id in stale { entries.removeValue(forKey: id) }
        try persist(orRestore: previous)
        return stale.sorted()
    }

    private func requireAvailable() throws {
        guard isAvailable else { throw HiddenSessionStoreError.unavailable }
    }

    private mutating func persist(orRestore previous: [String: HiddenSessionSnapshot]) throws {
        do {
            try file.write(entries)
            statusMessage = nil
        } catch {
            entries = previous
            throw HiddenSessionStoreError.writeFailed(error.localizedDescription)
        }
    }
}
