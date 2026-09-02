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

/// The one path-standardization policy for user-supplied project directories
/// (exclusions, saved Quick Create folders…). Lexical only: no symlink
/// resolution, no project contents read.
enum ProjectPathPolicy {
    static func standardized(_ rawPath: String) -> String? {
        let trimmed = (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !trimmed.isEmpty, (trimmed as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    /// Component-aware: `/work/client` covers `/work/client/app`, never
    /// `/work/client-old`.
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

    /// Dedupe key: the standardized path, case-folded when its volume ignores
    /// case. Cheaper than pairwise `sameDirectory` over a long list.
    static func comparisonKey(for rawPath: String) -> String? {
        guard let path = standardized(rawPath) else { return nil }
        return volumeIsCaseSensitive(at: path) ? path : path.folding(options: [.caseInsensitive], locale: nil)
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

/// Spotion-only directory exclusions. Fails closed like hidden sessions: an
/// unreadable policy file excludes everything rather than exposing a
/// confidential project.
struct ProjectExclusionStore: Sendable {
    private let file: PersistedJSON<[String]>
    private var paths: [String] = []
    private(set) var isAvailable = true
    private(set) var statusMessage: String?

    init(url: URL) {
        file = PersistedJSON(url: url, mirrorURL: url.appendingPathExtension("safety"), version: 1)
    }

    mutating func load() {
        paths = []
        isAvailable = true
        statusMessage = nil
        let loaded = file.load()
        switch loaded {
        case .empty:
            return
        case .loaded(let stored), .recovered(let stored):
            // A stored path that no longer standardizes to itself means the
            // file was hand-edited or written by an incompatible build.
            guard stored.allSatisfy({ ProjectPathPolicy.standardized($0) == $0 }) else { break }
            paths = stored
            if case .recovered = loaded {
                statusMessage = "Project exclusions were recovered from their safety copy."
            }
            return
        case .unreadable:
            break
        }
        isAvailable = false
        statusMessage = ProjectExclusionError.unavailable.localizedDescription
    }

    func exclusions() -> [ProjectExclusion] {
        paths.map(ProjectExclusion.init(path:)).sorted { $0.path < $1.path }
    }

    func excludes(cwd: String) -> Bool {
        guard isAvailable else { return true }
        return paths.contains { ProjectPathPolicy.contains(root: $0, candidate: cwd) }
    }

    func matchingExclusion(path rawPath: String) throws -> ProjectExclusion? {
        try requireAvailable()
        guard let path = ProjectPathPolicy.standardized(rawPath),
              let storedPath = paths.first(where: { ProjectPathPolicy.sameDirectory($0, path) })
        else { return nil }
        return ProjectExclusion(path: storedPath)
    }

    mutating func add(path rawPath: String) throws -> ProjectExclusion? {
        try requireAvailable()
        guard let path = ProjectPathPolicy.standardized(rawPath) else {
            throw ProjectExclusionError.invalidPath(rawPath)
        }
        guard !paths.contains(where: { ProjectPathPolicy.sameDirectory($0, path) }) else {
            return nil
        }
        let previous = paths
        paths.append(path)
        paths.sort()
        try persist(orRestore: previous)
        return ProjectExclusion(path: path)
    }

    mutating func remove(path rawPath: String) throws -> ProjectExclusion? {
        guard let exclusion = try matchingExclusion(path: rawPath),
              let index = paths.firstIndex(of: exclusion.path) else { return nil }
        let previous = paths
        let removed = paths.remove(at: index)
        try persist(orRestore: previous)
        return ProjectExclusion(path: removed)
    }

    private func requireAvailable() throws {
        guard isAvailable else { throw ProjectExclusionError.unavailable }
    }

    private mutating func persist(orRestore previous: [String]) throws {
        do {
            try file.write(paths)
            statusMessage = nil
        } catch {
            paths = previous
            throw ProjectExclusionError.writeFailed(error.localizedDescription)
        }
    }
}
