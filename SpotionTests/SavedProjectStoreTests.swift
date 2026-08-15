import Foundation
import Testing

@Suite(.serialized)
struct SavedProjectStoreTests {
    private func makeStore(
        root: URL,
        caseSensitive: Bool = true
    ) -> SavedProjectStore {
        SavedProjectStore(
            fileURL: root.appendingPathComponent("state/saved-projects.json"),
            pathPolicy: SavedProjectPathPolicy(caseSensitiveNames: { _ in caseSensitive })
        )
    }

    @Test
    func addDeduplicateReorderRemoveAndPersist() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = root.appendingPathComponent("Alpha Project", isDirectory: true)
        let beta = root.appendingPathComponent("βeta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        let store = makeStore(root: root)

        #expect(try await store.add(alpha.path))
        #expect(!(try await store.add(alpha.appendingPathComponent("../Alpha Project/").path)))
        #expect(try await store.add(beta.path))
        #expect(await store.projects().map(\.path) == [alpha.path, beta.path])

        try await store.move(from: 1, to: 0)
        #expect(await store.projects().map(\.path) == [beta.path, alpha.path])
        #expect(try await store.remove(alpha.path + "/./"))
        #expect(!(try await store.remove(alpha.path)))
        #expect(await store.projects().map(\.path) == [beta.path])

        let reloaded = makeStore(root: root)
        #expect(await reloaded.projects().map(\.path) == [beta.path])
    }

    @Test
    func recoversFromCorruptedPrimaryUsingSafetyCopy() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = makeStore(root: root)
        try await store.add(project.path)

        let primary = root.appendingPathComponent("state/saved-projects.json")
        try Data("not-json".utf8).write(to: primary)
        let recovered = makeStore(root: root)

        #expect(await recovered.projects().map(\.path) == [project.path])
        #expect(await recovered.storageWarning() == "Saved projects were recovered from the safety copy.")
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: primary)) is [String: Any])
    }

    @Test
    func missingSavedProjectRemainsVisibleButLeavesSuggestions() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Later Missing", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = makeStore(root: root)
        try await store.add(project.path)
        try FileManager.default.removeItem(at: project)

        let saved = await store.projects()
        #expect(saved == [SavedProject(path: project.path, isAvailable: false)])
        #expect(QuickCreateProjectMerger.merge(saved: saved, recent: [], limit: 10).isEmpty)

        do {
            _ = try await store.add(root.appendingPathComponent("Never Existed").path)
            Issue.record("Expected unavailable directory rejection")
        } catch let error as SavedProjectStore.StoreError {
            #expect(error == .notDirectory(root.appendingPathComponent("Never Existed").path))
        }
    }

    @Test
    func mergesSavedFirstThenUniqueRecentInExistingOrder() {
        let policy = SavedProjectPathPolicy(caseSensitiveNames: { _ in false })
        let saved = [
            SavedProject(path: "/Work/Alpha", isAvailable: true),
            SavedProject(path: "/Work/Beta", isAvailable: true),
            SavedProject(path: "/Work/Missing", isAvailable: false),
        ]
        let recent = [
            ProjectInfo(cwd: "/work/beta/./", name: "beta recent", lastUsed: Date(timeIntervalSince1970: 3)),
            ProjectInfo(cwd: "/Work/Gamma", name: "Gamma", lastUsed: Date(timeIntervalSince1970: 2)),
            ProjectInfo(cwd: "/Work/Alpha/", name: "alpha recent", lastUsed: Date(timeIntervalSince1970: 1)),
        ]

        let merged = QuickCreateProjectMerger.merge(
            saved: saved, recent: recent, limit: 10, pathPolicy: policy)
        #expect(merged.map(\.path) == ["/Work/Alpha", "/Work/Beta", "/Work/Gamma"])
        #expect(merged.map(\.name) == ["Alpha", "Beta", "Gamma"])

        let matching = QuickCreateProjectMerger.merge(
            saved: saved, recent: recent, matching: "gamma", limit: 10, pathPolicy: policy)
        #expect(matching == [QuickCreateProject(path: "/Work/Gamma", name: "Gamma")])
    }

    @Test
    func standardizationAndActiveVolumeCaseBehaviorAreDeterministic() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = SavedProjectPathPolicy()
        let canonical = try policy.standardizedPath(root.appendingPathComponent("A/../B/").path)
        #expect(canonical == root.appendingPathComponent("B").path)

        let values = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let upper = root.appendingPathComponent("CaseProject").path
        let lower = root.appendingPathComponent("caseproject").path
        let keysMatch = try policy.comparisonKey(for: upper) == policy.comparisonKey(for: lower)
        #expect(keysMatch == !(values.volumeSupportsCaseSensitiveNames ?? true))
    }

    @Test
    func removingSavedProjectDoesNotTouchSessionStateOrDefaults() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("scan-cache-v1.json")
        try Data("session-state".utf8).write(to: sentinel)
        let defaults = UserDefaults.standard
        let oldDefault = defaults.object(forKey: "defaultNewSessionDir")
        defer {
            if let oldDefault {
                defaults.set(oldDefault, forKey: "defaultNewSessionDir")
            } else {
                defaults.removeObject(forKey: "defaultNewSessionDir")
            }
        }
        defaults.set("/unchanged/default", forKey: "defaultNewSessionDir")
        let store = makeStore(root: root)
        try await store.add(project.path)

        try await store.remove(project.path)

        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "session-state")
        #expect(defaults.string(forKey: "defaultNewSessionDir") == "/unchanged/default")
    }
}
