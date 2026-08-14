import Foundation

struct ProjectExclusion: Codable, Sendable, Hashable, Identifiable {
    var path: String
    var id: String { path }
}

enum ProjectExclusionError: LocalizedError, Sendable {
    case invalidPath(String)
    case unavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            "Project exclusions require an absolute directory path: \(path)"
        case .unavailable:
            "Project-exclusion state is unreadable. Spotion indexing remains paused to prevent sensitive sessions from being exposed."
        case .writeFailed(let detail):
            "Project exclusions could not be saved: \(detail)"
        }
    }
}

enum ProjectPathPolicy {
    static func standardized(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (trimmed as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    static func contains(root rawRoot: String, candidate rawCandidate: String) -> Bool {
        guard let root = standardized(rawRoot), let candidate = standardized(rawCandidate) else {
            return false
        }
        let rootComponents = URL(fileURLWithPath: root).pathComponents
        let candidateComponents = URL(fileURLWithPath: candidate).pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }

        let caseSensitive = volumeIsCaseSensitive(at: root)
        for (rootComponent, candidateComponent) in zip(rootComponents, candidateComponents) {
            if caseSensitive {
                guard rootComponent == candidateComponent else { return false }
            } else {
                guard rootComponent.compare(candidateComponent, options: .caseInsensitive) == .orderedSame else {
                    return false
                }
            }
        }
        return true
    }

    static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        contains(root: lhs, candidate: rhs) && contains(root: rhs, candidate: lhs)
    }

    /// Resolve case behavior from the nearest existing ancestor. This handles
    /// missing/moved project directories without reading project contents.
    static func volumeIsCaseSensitive(at path: String) -> Bool {
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let manager = FileManager.default
        while !manager.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        return (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? true
    }
}

/// Independent policy persistence: resetting or migrating the scan cache must
/// never erase privacy exclusions. A mirrored safety file provides recovery;
/// if neither copy can be decoded, callers fail closed.
struct ProjectExclusionStore: Sendable {
    private struct Payload: Codable, Sendable {
        static let currentVersion = 1
        var version = Self.currentVersion
        var paths: [String] = []
    }

    private let primaryURL: URL
    private let safetyURL: URL
    private var payload = Payload()
    private(set) var isAvailable = true
    private(set) var statusMessage: String?

    init(url: URL) {
        primaryURL = url
        safetyURL = url.appendingPathExtension("safety")
    }

    mutating func load() {
        payload = Payload()
        isAvailable = true
        statusMessage = nil

        let manager = FileManager.default
        guard manager.fileExists(atPath: primaryURL.path)
                || manager.fileExists(atPath: safetyURL.path) else { return }

        if let primary = Self.read(primaryURL) {
            payload = primary
            try? Self.write(primary, to: safetyURL)
            return
        }
        if let safety = Self.read(safetyURL) {
            payload = safety
            statusMessage = "Project exclusions were recovered from their safety copy."
            try? Self.write(safety, to: primaryURL)
            return
        }

        isAvailable = false
        statusMessage = ProjectExclusionError.unavailable.localizedDescription
    }

    func exclusions() -> [ProjectExclusion] {
        payload.paths.map(ProjectExclusion.init(path:)).sorted { $0.path < $1.path }
    }

    func excludes(cwd: String) -> Bool {
        guard isAvailable else { return true }
        return payload.paths.contains { ProjectPathPolicy.contains(root: $0, candidate: cwd) }
    }

    mutating func add(path rawPath: String) throws -> ProjectExclusion? {
        try requireAvailable()
        guard let path = ProjectPathPolicy.standardized(rawPath) else {
            throw ProjectExclusionError.invalidPath(rawPath)
        }
        guard !payload.paths.contains(where: { ProjectPathPolicy.sameDirectory($0, path) }) else {
            return nil
        }

        let previous = payload
        payload.paths.append(path)
        payload.paths.sort()
        try save(orRestore: previous)
        statusMessage = nil
        return ProjectExclusion(path: path)
    }

    mutating func remove(path rawPath: String) throws -> ProjectExclusion? {
        try requireAvailable()
        guard let path = ProjectPathPolicy.standardized(rawPath),
              let index = payload.paths.firstIndex(where: {
                  ProjectPathPolicy.sameDirectory($0, path)
              }) else { return nil }

        let previous = payload
        let removed = payload.paths.remove(at: index)
        try save(orRestore: previous)
        statusMessage = nil
        return ProjectExclusion(path: removed)
    }

    private func requireAvailable() throws {
        guard isAvailable else { throw ProjectExclusionError.unavailable }
    }

    private mutating func save(orRestore previous: Payload) throws {
        do {
            try Self.write(payload, to: safetyURL)
            try Self.write(payload, to: primaryURL)
        } catch {
            payload = previous
            throw ProjectExclusionError.writeFailed(error.localizedDescription)
        }
    }

    private static func read(_ url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Payload.self, from: data),
              value.version == Payload.currentVersion,
              value.paths.allSatisfy({ ProjectPathPolicy.standardized($0) == $0 }) else {
            return nil
        }
        return value
    }

    private static func write(_ payload: Payload, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: url, options: .atomic)
    }
}
