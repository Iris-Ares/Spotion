import Foundation
import Testing

@Suite struct PinnedSessionStoreTests {
    @Test func addRemoveDuplicateAndPersistence() throws {
        let root = try TestSupport.makeTempDir()
        let url = root.appendingPathComponent("pins/pinned-sessions-v1.json")
        var store = PinnedSessionStore(url: url)
        store.bootstrap()

        #expect(try store.setPinned(true, id: "codex:one"))
        #expect(try !store.setPinned(true, id: "codex:one"))
        #expect(store.contains("codex:one"))

        var relaunched = PinnedSessionStore(url: url)
        relaunched.bootstrap()
        #expect(relaunched.sessionIDs == ["codex:one"])
        #expect(try relaunched.setPinned(false, id: "codex:one"))
        #expect(try !relaunched.setPinned(false, id: "codex:one"))
        #expect(relaunched.sessionIDs.isEmpty)
    }

    @Test func corruptedPersistenceRecoversEmptyAndCanBeReplaced() throws {
        let root = try TestSupport.makeTempDir()
        let url = try TestSupport.write("not json", to: root.appendingPathComponent("pins.json"))
        var store = PinnedSessionStore(url: url)
        store.bootstrap()
        #expect(store.sessionIDs.isEmpty)

        #expect(try store.setPinned(true, id: "claude:recovered"))
        var relaunched = PinnedSessionStore(url: url)
        relaunched.bootstrap()
        #expect(relaunched.sessionIDs == ["claude:recovered"])
    }

    @Test func staleIDsPruneDeterministically() throws {
        let root = try TestSupport.makeTempDir()
        let url = root.appendingPathComponent("pins.json")
        var store = PinnedSessionStore(url: url)
        store.bootstrap()
        try store.setPinned(true, id: "codex:keep")
        try store.setPinned(true, id: "claude:stale")

        #expect(try store.prune(validIDs: ["codex:keep"]))
        #expect(store.sessionIDs == ["codex:keep"])
        #expect(try !store.prune(validIDs: ["codex:keep"]))
    }

    @Test func donationPriorityMapping() {
        #expect(SessionDonationPriority.value(isPinned: false) == 0)
        #expect(SessionDonationPriority.value(isPinned: true) > 0)
    }
}
