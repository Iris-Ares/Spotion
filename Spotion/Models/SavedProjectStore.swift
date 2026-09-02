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

/// Ordered, user-curated folders offered first by Quick Create. Independent of
/// the scan cache; mirrored so a torn write still leaves one complete ordering.
/// Fails open: unreadable storage resets to an empty list with a warning.
struct SavedProjectStore: Sendable {
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

    private let file: PersistedJSON<[String]>
    private let directoryCheck: @Sendable (String) -> Bool
    private(set) var paths: [String] = []
    private(set) var warning: String?

    init(
        fileURL: URL,
        directoryCheck: @escaping @Sendable (String) -> Bool = SavedProjectStore.directoryExists
    ) {
        file = PersistedJSON(
            url: fileURL,
            mirrorURL: fileURL.deletingPathExtension().appendingPathExtension("recovery.json"),
            version: 1)
        self.directoryCheck = directoryCheck
    }

    mutating func load() {
        paths = []
        warning = nil
        switch file.load() {
        case .empty:
            break
        case .loaded(let stored):
            paths = deduplicated(stored)
        case .recovered(let stored):
            paths = deduplicated(stored)
            warning = "Saved projects were recovered from the safety copy."
        case .unreadable:
            warning = "Saved project storage was unreadable and has been reset."
        }
    }

    /// Missing or unmounted folders stay listed (so the user can see and remove
    /// them) but are flagged unavailable and never suggested.
    func projects() -> [SavedProject] {
        paths.map { SavedProject(path: $0, isAvailable: directoryCheck($0)) }
    }

    @discardableResult
    mutating func add(_ rawPath: String) throws -> Bool {
        guard let path = ProjectPathPolicy.standardized(rawPath) else {
            throw StoreError.pathMustBeAbsolute(rawPath)
        }
        guard directoryCheck(path) else { throw StoreError.notDirectory(path) }
        let key = ProjectPathPolicy.comparisonKey(for: path)
        guard !paths.contains(where: { ProjectPathPolicy.comparisonKey(for: $0) == key }) else {
            return false
        }
        try commit(paths + [path])
        return true
    }

    @discardableResult
    mutating func remove(_ rawPath: String) throws -> Bool {
        guard let key = ProjectPathPolicy.comparisonKey(for: rawPath) else {
            throw StoreError.pathMustBeAbsolute(rawPath)
        }
        guard let index = paths.firstIndex(where: { ProjectPathPolicy.comparisonKey(for: $0) == key }) else {
            return false
        }
        var updated = paths
        updated.remove(at: index)
        try commit(updated)
        return true
    }

    mutating func move(from source: Int, to destination: Int) throws {
        guard paths.indices.contains(source), paths.indices.contains(destination) else {
            throw StoreError.invalidMove
        }
        guard source != destination else { return }
        var updated = paths
        let path = updated.remove(at: source)
        updated.insert(path, at: destination)
        try commit(updated)
    }

    /// In-memory state changes only after the atomic write succeeds.
    private mutating func commit(_ updated: [String]) throws {
        try file.write(updated)
        paths = updated
        warning = nil
    }

    private func deduplicated(_ loaded: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawPath in loaded {
            guard let path = ProjectPathPolicy.standardized(rawPath),
                  let key = ProjectPathPolicy.comparisonKey(for: path),
                  seen.insert(key).inserted else { continue }
            result.append(path)
        }
        return result
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

/// Quick Create's Project parameter: available saved folders in user order,
/// then unique recent-session projects in recency order.
enum QuickCreateProjectMerger {
    static func merge(
        saved: [SavedProject],
        recent: [ProjectInfo],
        matching query: String? = nil,
        limit: Int
    ) -> [QuickCreateProject] {
        var seen = Set<String>()
        var merged: [QuickCreateProject] = []

        func append(path rawPath: String, name: String) {
            guard let path = ProjectPathPolicy.standardized(rawPath),
                  let key = ProjectPathPolicy.comparisonKey(for: path),
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
