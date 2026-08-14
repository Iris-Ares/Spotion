import Foundation
import Testing

@Suite struct ProjectExclusionStoreTests {
    @Test func componentAwarePathPolicy() {
        #expect(ProjectPathPolicy.standardized("/work/client/./app/..") == "/work/client")
        #expect(ProjectPathPolicy.standardized("relative/path") == nil)
        #expect(ProjectPathPolicy.contains(root: "/work/client", candidate: "/work/client"))
        #expect(ProjectPathPolicy.contains(root: "/work/client/", candidate: "/work/client/app"))
        #expect(!ProjectPathPolicy.contains(root: "/work/client", candidate: "/work/client-old"))
        #expect(!ProjectPathPolicy.contains(root: "/work/client/app", candidate: "/work/client"))
        #expect(ProjectPathPolicy.contains(root: "/", candidate: "/work/client"))
    }

    @Test func matchingUsesActiveVolumeCaseBehavior() throws {
        let root = try TestSupport.makeTempDir().appendingPathComponent("CaseSensitiveProbe")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alternate = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent.lowercased()).path
        let expected = !ProjectPathPolicy.volumeIsCaseSensitive(at: root.path)
            || alternate == root.path
        #expect(ProjectPathPolicy.sameDirectory(root.path, alternate) == expected)
    }

    @Test func persistenceIdempotencyAndOverlappingRules() throws {
        let root = try TestSupport.makeTempDir()
        let url = root.appendingPathComponent("state/exclusions.json")
        var store = ProjectExclusionStore(url: url)
        store.load()

        #expect(try store.add(path: "/work/client/")?.path == "/work/client")
        #expect(try store.add(path: "/work/client/./") == nil)
        #expect(try store.add(path: "/work/client/app")?.path == "/work/client/app")
        #expect(store.excludes(cwd: "/work/client/app/subproject"))
        #expect(!store.excludes(cwd: "/work/client-old"))

        var relaunched = ProjectExclusionStore(url: url)
        relaunched.load()
        #expect(relaunched.exclusions().map(\.path) == ["/work/client", "/work/client/app"])
        #expect(try relaunched.remove(path: "/work/client/app/")?.path == "/work/client/app")
        #expect(relaunched.excludes(cwd: "/work/client/app"))  // parent still covers it
        #expect(try relaunched.remove(path: "/work/client")?.path == "/work/client")
        #expect(try relaunched.remove(path: "/work/client") == nil)
        #expect(!relaunched.excludes(cwd: "/work/client/app"))
    }

    @Test func recoveryCopyAndDoubleCorruptionFailClosed() throws {
        let root = try TestSupport.makeTempDir()
        let url = root.appendingPathComponent("state/exclusions.json")
        let safetyURL = url.appendingPathExtension("safety")
        var store = ProjectExclusionStore(url: url)
        store.load()
        _ = try store.add(path: "/private/client")

        try TestSupport.write("not json", to: url)
        var recovered = ProjectExclusionStore(url: url)
        recovered.load()
        #expect(recovered.isAvailable)
        #expect(recovered.excludes(cwd: "/private/client/app"))
        #expect(recovered.statusMessage?.contains("recovered") == true)

        try TestSupport.write("bad primary", to: url)
        try TestSupport.write("bad safety", to: safetyURL)
        var failedClosed = ProjectExclusionStore(url: url)
        failedClosed.load()
        #expect(!failedClosed.isAvailable)
        #expect(failedClosed.excludes(cwd: "/unrelated/project"))
        #expect(failedClosed.statusMessage?.contains("paused") == true)
    }
}
