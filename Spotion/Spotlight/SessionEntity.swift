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
    var laterPromptSnippets: [String]
    var gitBranch: String?
    var startedAt: Date?
    var lastActivityAt: Date
    var sourceHomeDisplayPath: String?

    init(_ titled: TitledSession) {
        let record = titled.record
        self.id = record.id
        self.title = titled.title
        self.projectName = record.projectName
        self.cwd = record.cwd
        self.agent = record.agent
        self.firstPromptSnippet = record.firstPrompt
        self.laterPromptSnippets = record.laterPromptSnippets
        self.gitBranch = record.gitBranch
        self.startedAt = record.startedAt
        self.lastActivityAt = record.lastActivityAt
        self.sourceHomeDisplayPath = record.sourceHomeDisplayPath
    }

    var displayRepresentation: DisplayRepresentation {
        // Same artwork as the Spotlight thumbnail (agent app icon → Spotion
        // icon); the symbol is a last resort when no bitmap could be rendered.
        let image: DisplayRepresentation.Image = if let png = AgentIconProvider.shared.thumbnailPNG(for: agent) {
            .init(data: png)
        } else {
            .init(systemName: agent == .codex
                ? "chevron.left.forwardslash.chevron.right"
                : "asterisk.circle")
        }
        let subtitle = if let sourceHomeDisplayPath {
            "\(agent.displayName) · \(projectName) · \(sourceHomeDisplayPath)"
        } else {
            "\(agent.displayName) · \(projectName)"
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: image
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        attributes.contentDescription = SessionRecord.spotlightContentDescription(
            firstPrompt: firstPromptSnippet,
            laterPrompts: laterPromptSnippets,
            cwd: cwd,
            includeLaterPrompts: SpotionSettings.searchLaterPrompts
        )
        var keywords = [projectName, agent.displayName, agent.rawValue, "session"]
        if let gitBranch { keywords.append(gitBranch) }
        if let sourceHomeDisplayPath { keywords.append(sourceHomeDisplayPath) }
        keywords += cwd.split(separator: "/").map(String.init)
        attributes.keywords = keywords
        attributes.contentCreationDate = startedAt
        attributes.contentModificationDate = lastActivityAt
        // Grouped by agent domain, enabling bulk deletion when an agent is disabled
        attributes.domainIdentifier = "spotion.\(agent.rawValue)"
        // Without a thumbnail Spotlight renders a blank placeholder; the
        // provider guarantees meaningful artwork (agent app icon or Spotion's).
        attributes.thumbnailData = AgentIconProvider.shared.thumbnailPNG(for: agent)
        return attributes
    }
}
