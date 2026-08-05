import AppIntents

/// Quick Create 的可选 "Project" 参数：来自已知会话的去重 cwd，最近使用优先。
struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = ProjectEntityQuery()

    /// id = 绝对路径
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)")
    }
}

struct ProjectEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        identifiers.map { ProjectEntity(id: $0, name: ($0 as NSString).lastPathComponent) }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        await AppCoordinator.shared.recentProjects(limit: 10)
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        await AppCoordinator.shared.matchingProjects(string, limit: 20)
    }
}
