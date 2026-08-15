import Foundation

struct SavedProject: Identifiable, Sendable, Equatable {
    var path: String
    var isAvailable: Bool

    var id: String { path }
    var name: String {
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? path : component
    }
}

/// Standardizes paths without resolving symlinks and compares them according
/// to the volume that owns the path. Missing paths fall back to the nearest
/// existing ancestor's volume; case-sensitive is the conservative fallback.
struct SavedProjectPathPolicy: Sendable {
    private let caseSensitiveNames: @Sendable (String) -> Bool

    init(caseSensitiveNames: @escaping @Sendable (String) -> Bool = Self.caseSensitiveNames) {
        self.caseSensitiveNames = caseSensitiveNames
    }

    func standardizedPath(_ rawPath: String) throws -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else {
            throw SavedProjectStore.StoreError.pathMustBeAbsolute(rawPath)
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    func comparisonKey(for rawPath: String) throws -> String {
        let path = try standardizedPath(rawPath)
        guard !caseSensitiveNames(path) else { return path }
        return path.folding(options: [.caseInsensitive], locale: nil)
    }

    private static func caseSensitiveNames(_ path: String) -> Bool {
        var candidate = URL(fileURLWithPath: path, isDirectory: true)
        while true {
            if let values = try? candidate.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
               let isCaseSensitive = values.volumeSupportsCaseSensitiveNames {
                return isCaseSensitive
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return true }
            candidate = parent
        }
    }
}

actor SavedProjectStore {
    enum StoreError: LocalizedError, Equatable {
        case pathMustBeAbsolute(String)
        case notDirectory(String)
        case invalidMove

        var errorDescription: String? {
            switch self {
            case .pathMustBeAbsolute(let path): "项目目录必须是绝对路径：\(path)"
            case .notDirectory(let path): "项目目录不存在或不可用：\(path)"
            case .invalidMove: "无法调整项目顺序"
            }
        }
    }

    private struct Payload: Codable {
        static let currentVersion = 1
        var version = currentVersion
        var paths: [String]
    }

    private let fileURL: URL
    private let recoveryURL: URL
    private let pathPolicy: SavedProjectPathPolicy
    private let directoryCheck: @Sendable (String) -> Bool
    private var didLoad = false
    private var paths: [String] = []
    private var warning: String?

    init(
        fileURL: URL,
        pathPolicy: SavedProjectPathPolicy = SavedProjectPathPolicy(),
        directoryCheck: @escaping @Sendable (String) -> Bool = SavedProjectStore.directoryExists
    ) {
        self.fileURL = fileURL
        self.recoveryURL = fileURL.deletingPathExtension().appendingPathExtension("recovery.json")
        self.pathPolicy = pathPolicy
        self.directoryCheck = directoryCheck
    }

    func projects() -> [SavedProject] {
        loadIfNeeded()
        return paths.map { SavedProject(path: $0, isAvailable: directoryCheck($0)) }
    }

    func storageWarning() -> String? {
        loadIfNeeded()
        return warning
    }

    @discardableResult
    func add(_ rawPath: String) throws -> Bool {
        loadIfNeeded()
        let path = try pathPolicy.standardizedPath(rawPath)
        guard directoryCheck(path) else { throw StoreError.notDirectory(path) }
        let key = try pathPolicy.comparisonKey(for: path)
        guard !paths.contains(where: { (try? pathPolicy.comparisonKey(for: $0)) == key }) else {
            return false
        }
        let previous = paths
        paths.append(path)
        do {
            try persist()
            return true
        } catch {
            paths = previous
            throw error
        }
    }

    @discardableResult
    func remove(_ rawPath: String) throws -> Bool {
        loadIfNeeded()
        let key = try pathPolicy.comparisonKey(for: rawPath)
        guard let index = paths.firstIndex(where: {
            (try? pathPolicy.comparisonKey(for: $0)) == key
        }) else { return false }
        let previous = paths
        paths.remove(at: index)
        do {
            try persist()
            return true
        } catch {
            paths = previous
            throw error
        }
    }

    func move(from source: Int, to destination: Int) throws {
        loadIfNeeded()
        guard paths.indices.contains(source), paths.indices.contains(destination) else {
            throw StoreError.invalidMove
        }
        guard source != destination else { return }
        let previous = paths
        let path = paths.remove(at: source)
        paths.insert(path, at: destination)
        do {
            try persist()
        } catch {
            paths = previous
            throw error
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        let primaryExists = FileManager.default.fileExists(atPath: fileURL.path)
        let recoveryExists = FileManager.default.fileExists(atPath: recoveryURL.path)
        if let loaded = decode(fileURL) {
            paths = deduplicated(loaded)
            return
        }
        if let recovered = decode(recoveryURL) {
            paths = deduplicated(recovered)
            let recoveryWarning = "Saved projects were recovered from the safety copy."
            try? persist()
            warning = recoveryWarning
            return
        }
        if primaryExists || recoveryExists {
            warning = "Saved project storage was unreadable and has been reset."
        }
    }

    private func decode(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Payload.currentVersion else { return nil }
        return payload.paths
    }

    private func deduplicated(_ loaded: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawPath in loaded {
            guard let path = try? pathPolicy.standardizedPath(rawPath),
                  let key = try? pathPolicy.comparisonKey(for: path),
                  seen.insert(key).inserted else { continue }
            result.append(path)
        }
        return result
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(Payload(paths: paths))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Write the safety copy first. A crash or primary-write failure still
        // leaves one complete copy of the new ordering.
        try data.write(to: recoveryURL, options: .atomic)
        try data.write(to: fileURL, options: .atomic)
        warning = nil
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

struct QuickCreateProject: Sendable, Equatable {
    var path: String
    var name: String
}

enum QuickCreateProjectMerger {
    static func merge(
        saved: [SavedProject],
        recent: [ProjectInfo],
        matching query: String? = nil,
        limit: Int,
        pathPolicy: SavedProjectPathPolicy = SavedProjectPathPolicy()
    ) -> [QuickCreateProject] {
        var seen = Set<String>()
        var merged: [QuickCreateProject] = []

        func append(path rawPath: String, name: String) {
            guard let path = try? pathPolicy.standardizedPath(rawPath),
                  let key = try? pathPolicy.comparisonKey(for: path),
                  seen.insert(key).inserted else { return }
            merged.append(QuickCreateProject(path: path, name: name))
        }

        for project in saved where project.isAvailable {
            append(path: project.path, name: project.name)
        }
        for project in recent {
            append(path: project.cwd, name: project.name)
        }

        if let query, !query.isEmpty {
            let needle = query.folding(options: [.caseInsensitive], locale: nil)
            merged = merged.filter {
                $0.name.folding(options: [.caseInsensitive], locale: nil).contains(needle)
                    || $0.path.folding(options: [.caseInsensitive], locale: nil).contains(needle)
            }
        }
        return Array(merged.prefix(max(0, limit)))
    }
}
