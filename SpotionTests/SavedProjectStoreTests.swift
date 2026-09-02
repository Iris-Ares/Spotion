import Foundation
import Testing

@Suite(.serialized)
struct SavedProjectStoreTests {
    private func makeStore(root: URL) -> SavedProjectStore {
        var store = SavedProjectStore(fileURL: root.appendingPathComponent("state/saved-projects.json"))
        store.load()
        return store
    }

    @Test
    func addDeduplicateReorderRemoveAndPersist() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = root.appendingPathComponent("Alpha Project", isDirectory: true)
        let beta = root.appendingPathComponent("βeta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        var store = makeStore(root: root)

        #expect(try store.add(alpha.path))
        #expect(!(try store.add(alpha.appendingPathComponent("../Alpha Project/").path)))
        #expect(try store.add(beta.path))
        #expect(store.projects().map(\.path) == [alpha.path, beta.path])

        try store.move(from: 1, to: 0)
        #expect(store.projects().map(\.path) == [beta.path, alpha.path])
        #expect(try store.remove(alpha.path + "/./"))
        #expect(!(try store.remove(alpha.path)))
        #expect(store.projects().map(\.path) == [beta.path])

        let reloaded = makeStore(root: root)
        #expect(reloaded.projects().map(\.path) == [beta.path])
    }

    @Test
    func recoversFromCorruptedPrimaryUsingSafetyCopy() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var store = makeStore(root: root)
        try store.add(project.path)

        let primary = root.appendingPathComponent("state/saved-projects.json")
        try Data("not-json".utf8).write(to: primary)
        let recovered = makeStore(root: root)

        #expect(recovered.projects().map(\.path) == [project.path])
        #expect(recovered.warning == "Saved projects were recovered from the safety copy.")
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: primary)) is [String: Any])
    }

    @Test
    func missingSavedProjectRemainsVisibleButLeavesSuggestions() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Later Missing", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var store = makeStore(root: root)
        try store.add(project.path)
        try FileManager.default.removeItem(at: project)

        let saved = store.projects()
        #expect(saved == [SavedProject(path: project.path, isAvailable: false)])
        #expect(QuickCreateProjectMerger.merge(saved: saved, recent: [], limit: 10).isEmpty)

        do {
            _ = try store.add(root.appendingPathComponent("Never Existed").path)
            Issue.record("Expected unavailable directory rejection")
        } catch let error as SavedProjectStore.StoreError {
            #expect(error == .notDirectory(root.appendingPathComponent("Never Existed").path))
        }
    }

    @Test
    func mergesSavedFirstThenUniqueRecentInExistingOrder() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = root.appendingPathComponent("Alpha").path
        let beta = root.appendingPathComponent("Beta").path
        let gamma = root.appendingPathComponent("Gamma").path
        let saved = [
            SavedProject(path: alpha, isAvailable: true),
            SavedProject(path: beta, isAvailable: true),
            SavedProject(path: root.appendingPathComponent("Missing").path, isAvailable: false),
        ]
        let recent = [
            ProjectInfo(cwd: beta + "/./", name: "beta recent", lastUsed: Date(timeIntervalSince1970: 3)),
            ProjectInfo(cwd: gamma, name: "Gamma", lastUsed: Date(timeIntervalSince1970: 2)),
            ProjectInfo(cwd: alpha + "/", name: "alpha recent", lastUsed: Date(timeIntervalSince1970: 1)),
        ]

        let merged = QuickCreateProjectMerger.merge(saved: saved, recent: recent, limit: 10)
        #expect(merged.map(\.path) == [alpha, beta, gamma])
        #expect(merged.map(\.name) == ["Alpha", "Beta", "Gamma"])

        let matching = QuickCreateProjectMerger.merge(saved: saved, recent: recent, matching: "gamma", limit: 10)
        #expect(matching == [QuickCreateProject(path: gamma, name: "Gamma")])
    }

    @Test
    func standardizationAndActiveVolumeCaseBehaviorAreDeterministic() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = ProjectPathPolicy.standardized(root.appendingPathComponent("A/../B/").path)
        #expect(canonical == root.appendingPathComponent("B").path)

        let values = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let upper = root.appendingPathComponent("CaseProject").path
        let lower = root.appendingPathComponent("caseproject").path
        let keysMatch = ProjectPathPolicy.comparisonKey(for: upper) == ProjectPathPolicy.comparisonKey(for: lower)
        #expect(keysMatch == !(values.volumeSupportsCaseSensitiveNames ?? true))
    }

    @Test
    func removingSavedProjectDoesNotTouchSessionStateOrDefaults() throws {
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
        var store = makeStore(root: root)
        try store.add(project.path)

        try store.remove(project.path)

        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "session-state")
        #expect(defaults.string(forKey: "defaultNewSessionDir") == "/unchanged/default")
    }
}
