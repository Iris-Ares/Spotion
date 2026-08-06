import AppIntents
import CoreSpotlight

struct SessionEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Session")
    static let defaultQuery = SessionEntityQuery()

    var id: String
    var title: String
    var projectName: String
    var cwd: String
    var agent: AgentKind
    var firstPromptSnippet: String?
    var gitBranch: String?
    var startedAt: Date?
    var lastActivityAt: Date

    init(_ titled: TitledSession) {
        let record = titled.record
        self.id = record.id
        self.title = titled.title
        self.projectName = record.projectName
        self.cwd = record.cwd
        self.agent = record.agent
        self.firstPromptSnippet = record.firstPrompt
        self.gitBranch = record.gitBranch
        self.startedAt = record.startedAt
        self.lastActivityAt = record.lastActivityAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(agent.displayName) · \(projectName)",
            image: .init(systemName: agent == .codex
                ? "chevron.left.forwardslash.chevron.right"
                : "asterisk.circle")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        attributes.contentDescription = [firstPromptSnippet, cwd]
            .compactMap { $0 }
            .joined(separator: "\n")
        var keywords = [projectName, agent.displayName, agent.rawValue, "session"]
        if let gitBranch { keywords.append(gitBranch) }
        keywords += cwd.split(separator: "/").map(String.init)
        attributes.keywords = keywords
        attributes.contentCreationDate = startedAt
        attributes.contentModificationDate = lastActivityAt
        // Grouped by agent domain, enabling bulk deletion when an agent is disabled
        attributes.domainIdentifier = "spotion.\(agent.rawValue)"
        return attributes
    }
}
