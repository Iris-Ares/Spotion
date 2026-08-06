import AppIntents

struct SessionEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        await AppCoordinator.shared.entities(for: identifiers)
    }

    func suggestedEntities() async throws -> [SessionEntity] {
        await AppCoordinator.shared.recentEntities(limit: 10)
    }

    func entities(matching string: String) async throws -> [SessionEntity] {
        await AppCoordinator.shared.matchingEntities(string, limit: 20)
    }
}
