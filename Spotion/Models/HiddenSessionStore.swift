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

/// Versioned persistence for Spotion-only hide state. It lives beside, but is
/// independent from, the scan cache so cache resets and schema migrations do
/// not make hidden sessions visible again.
struct HiddenSessionStore: Sendable {
    private struct State: Codable, Sendable {
        static let currentVersion = 1

        var version = currentVersion
        var entries: [String: HiddenSessionSnapshot] = [:]
    }

    private let url: URL
    private let recoveryURL: URL
    private var state = State()
    private(set) var isAvailable = true
    private(set) var statusMessage: String?

    init(url: URL) {
        self.url = url
        recoveryURL = url.appendingPathExtension("recovery")
    }

    mutating func load() {
        state = State()
        isAvailable = true
        statusMessage = nil

        let manager = FileManager.default
        let primaryExists = manager.fileExists(atPath: url.path)
        let recoveryExists = manager.fileExists(atPath: recoveryURL.path)
        guard primaryExists || recoveryExists else { return }

        if let loaded = Self.decode(from: url) {
            state = loaded
            try? Self.write(loaded, to: recoveryURL)
            return
        }
        if let recovered = Self.decode(from: recoveryURL) {
            state = recovered
            statusMessage = "Hidden-session state was recovered from its safety copy."
            try? Self.write(recovered, to: url)
            return
        }

        isAvailable = false
        statusMessage = HiddenSessionStoreError.unavailable.localizedDescription
    }

    var hiddenIDs: Set<String> { Set(state.entries.keys) }

    func contains(_ id: String) -> Bool {
        state.entries[id] != nil
    }

    func allowsVisibility(of id: String) -> Bool {
        isAvailable && state.entries[id] == nil
    }

    func snapshots() -> [HiddenSessionSnapshot] {
        state.entries.values.sorted {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
        }
    }

    mutating func hide(_ snapshot: HiddenSessionSnapshot) throws -> Bool {
        try requireAvailable()
        guard state.entries[snapshot.id] == nil else { return false }
        let previous = state
        state.entries[snapshot.id] = snapshot
        try persist(orRestore: previous)
        statusMessage = nil
        return true
    }

    mutating func restore(id: String) throws -> Bool {
        try requireAvailable()
        guard state.entries[id] != nil else { return false }
        let previous = state
        state.entries.removeValue(forKey: id)
        try persist(orRestore: previous)
        statusMessage = nil
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
        let stale = state.entries.values.filter {
            trustworthyAgents.contains($0.agent) && !validIDs.contains($0.id)
        }.map(\.id)
        guard !stale.isEmpty else { return [] }

        let previous = state
        for id in stale { state.entries.removeValue(forKey: id) }
        try persist(orRestore: previous)
        statusMessage = nil
        return stale.sorted()
    }

    private func requireAvailable() throws {
        guard isAvailable else { throw HiddenSessionStoreError.unavailable }
    }

    private mutating func persist(orRestore previous: State) throws {
        do {
            // Write the safety copy first. If the primary later becomes
            // unreadable, a relaunch can recover the exact acknowledged state.
            try Self.write(state, to: recoveryURL)
            try Self.write(state, to: url)
        } catch {
            state = previous
            throw HiddenSessionStoreError.writeFailed(error.localizedDescription)
        }
    }

    private static func decode(from url: URL) -> State? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(State.self, from: data),
              decoded.version == State.currentVersion else { return nil }
        return decoded
    }

    private static func write(_ state: State, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
