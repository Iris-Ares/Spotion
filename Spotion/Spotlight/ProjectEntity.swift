import AppIntents

/// The optional "Project" parameter for Quick Create: deduplicated cwds of
/// known sessions, most recently used first.
struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = ProjectEntityQuery()

    /// id = absolute path
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
