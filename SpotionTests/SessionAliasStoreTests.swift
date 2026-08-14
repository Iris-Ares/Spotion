import Foundation
import Testing

@Suite struct SessionAliasStoreTests {
    @Test func setReplaceClearAndPersistence() throws {
        let root = try TestSupport.makeTempDir()
        let url = root.appendingPathComponent("aliases/session-aliases-v1.json")
        var store = SessionAliasStore(url: url)
        store.bootstrap()

        #expect(try store.setAlias("  Architecture   handoff  ", for: "codex:one"))
        #expect(store.alias(for: "codex:one") == "Architecture handoff")
        #expect(try !store.setAlias("Architecture handoff", for: "codex:one"))
        #expect(try store.setAlias("Replacement", for: "codex:one"))

        var relaunched = SessionAliasStore(url: url)
        relaunched.bootstrap()
        #expect(relaunched.alias(for: "codex:one") == "Replacement")
        #expect(try relaunched.clearAlias(for: "codex:one"))
        #expect(try !relaunched.clearAlias(for: "codex:one"))
    }

    @Test func boundsAndRejectsWhitespaceOnly() throws {
        let root = try TestSupport.makeTempDir()
        var store = SessionAliasStore(url: root.appendingPathComponent("aliases.json"))
        store.bootstrap()
        #expect(throws: SessionAliasError.empty) {
            try store.setAlias(" \n\t ", for: "codex:one")
        }
        try store.setAlias(String(repeating: "x", count: 150), for: "codex:one")
        #expect(store.alias(for: "codex:one")?.count == 100)
    }

    @Test func corruptionIsVisibleAndRecoverable() throws {
        let root = try TestSupport.makeTempDir()
        let url = try TestSupport.write("not json", to: root.appendingPathComponent("aliases.json"))
        var store = SessionAliasStore(url: url)
        store.bootstrap()
        #expect(store.aliases.isEmpty)
        #expect(store.loadWarning != nil)

        try store.setAlias("Recovered", for: "claude:one")
        #expect(store.loadWarning == nil)
        var relaunched = SessionAliasStore(url: url)
        relaunched.bootstrap()
        #expect(relaunched.alias(for: "claude:one") == "Recovered")
    }

    @Test func staleAliasesPrune() throws {
        let root = try TestSupport.makeTempDir()
        var store = SessionAliasStore(url: root.appendingPathComponent("aliases.json"))
        store.bootstrap()
        try store.setAlias("Keep", for: "codex:keep")
        try store.setAlias("Drop", for: "claude:stale")
        #expect(try store.prune(validIDs: ["codex:keep"]))
        #expect(store.aliases == ["codex:keep": "Keep"])
    }

    @Test func keywordMetadataKeepsAliasAndSourceWithoutDuplicates() {
        let keywords = SessionSearchMetadata.keywords(
            displayTitle: "My Alias",
            sourceTitle: "Original Agent Title",
            projectName: "Spotion",
            agent: .codex,
            gitBranch: "feature/aliases",
            cwd: "/work/Spotion"
        )
        #expect(keywords.contains("My Alias"))
        #expect(keywords.contains("Original Agent Title"))
        #expect(keywords.contains("feature/aliases"))
        #expect(Set(keywords.map { $0.lowercased() }).count == keywords.count)

        let sameTitle = SessionSearchMetadata.keywords(
            displayTitle: "Same",
            sourceTitle: "same",
            projectName: "Project",
            agent: .claude,
            gitBranch: nil,
            cwd: "/work/Project"
        )
        #expect(sameTitle.filter { $0.lowercased() == "same" }.count == 1)
    }
}
