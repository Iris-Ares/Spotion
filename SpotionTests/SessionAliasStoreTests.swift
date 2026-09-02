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
}
