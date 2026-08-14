import Foundation
import Testing

@Suite struct HiddenSessionStoreTests {
    private func snapshot(id: String = "codex:abc") -> HiddenSessionSnapshot {
        HiddenSessionSnapshot(
            id: id,
            agent: .codex,
            title: "Important session",
            projectName: "Spotion",
            cwd: "/work/Spotion",
            filePath: "/tmp/session.jsonl")
    }

    @Test func hideRestorePersistenceAndIdempotency() throws {
        let root = try TestSupport.makeTempDir()
        let url = root.appendingPathComponent("state/hidden.json")
        var store = HiddenSessionStore(url: url)
        store.load()

        #expect(try store.hide(snapshot()))
        #expect(try !store.hide(snapshot()))
        #expect(store.hiddenIDs == ["codex:abc"])
        #expect(!store.allowsVisibility(of: "codex:abc"))

        var relaunched = HiddenSessionStore(url: url)
        relaunched.load()
        #expect(relaunched.snapshots() == [snapshot()])
        #expect(try relaunched.restore(id: "codex:abc"))
        #expect(try !relaunched.restore(id: "codex:abc"))

        var restoredRelaunch = HiddenSessionStore(url: url)
        restoredRelaunch.load()
        #expect(restoredRelaunch.hiddenIDs.isEmpty)
    }

    @Test func corruptedPrimaryRecoversAndDoubleCorruptionFailsClosed() throws {
        let root = try TestSupport.makeTempDir()
        let url = root.appendingPathComponent("state/hidden.json")
        let recoveryURL = url.appendingPathExtension("recovery")
        var store = HiddenSessionStore(url: url)
        store.load()
        _ = try store.hide(snapshot())

        try TestSupport.write("not json", to: url)
        var recovered = HiddenSessionStore(url: url)
        recovered.load()
        #expect(recovered.isAvailable)
        #expect(recovered.hiddenIDs == ["codex:abc"])
        #expect(recovered.statusMessage?.contains("recovered") == true)

        try TestSupport.write("still not json", to: url)
        try TestSupport.write("also not json", to: recoveryURL)
        var failedClosed = HiddenSessionStore(url: url)
        failedClosed.load()
        #expect(!failedClosed.isAvailable)
        #expect(!failedClosed.allowsVisibility(of: "claude:any"))
        #expect(failedClosed.statusMessage?.contains("paused") == true)
    }

    @Test func pruneRequiresTrustworthyEnabledAgent() throws {
        let root = try TestSupport.makeTempDir()
        var store = HiddenSessionStore(url: root.appendingPathComponent("hidden.json"))
        store.load()
        _ = try store.hide(snapshot())

        #expect(try store.pruneMissing(validIDs: [], trustworthyAgents: [.claude]).isEmpty)
        #expect(store.hiddenIDs == ["codex:abc"])
        #expect(try store.pruneMissing(validIDs: [], trustworthyAgents: [.codex]) == ["codex:abc"])
        #expect(store.hiddenIDs.isEmpty)
    }
}
