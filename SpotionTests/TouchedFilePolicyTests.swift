import Foundation
import Testing

@Suite struct TouchedFilePolicyTests {
    @Test func normalizesOnlyLexicallyContainedProjectFiles() {
        let cwd = "/work/client"
        #expect(TouchedFilePolicy.normalize(
            "/work/client/Sources/../Sources/Auth Service.swift",
            relativeTo: cwd,
            caseSensitive: true
        ) == "Sources/Auth Service.swift")
        #expect(TouchedFilePolicy.normalize(
            "./Tests/登录 Tests.swift",
            relativeTo: cwd,
            caseSensitive: true
        ) == "Tests/登录 Tests.swift")
        #expect(TouchedFilePolicy.normalize(
            "../client-old/Secret.swift",
            relativeTo: cwd,
            caseSensitive: true
        ) == nil)
        #expect(TouchedFilePolicy.normalize(
            "/work/client-old/Secret.swift",
            relativeTo: cwd,
            caseSensitive: true
        ) == nil)
        #expect(TouchedFilePolicy.normalize("Sources/", relativeTo: cwd, caseSensitive: true) == nil)
        #expect(TouchedFilePolicy.normalize("~/.ssh/config", relativeTo: cwd, caseSensitive: true) == nil)
        #expect(TouchedFilePolicy.normalize("Sources/Bad\nName.swift", relativeTo: cwd, caseSensitive: true) == nil)
    }

    @Test func newestDistinctOrderingHonorsCaseBehavior() {
        let paths = [
            "Sources/Auth.swift",
            "Tests/Login.swift",
            "sources/AUTH.swift",
            "Docs/Guide.md",
        ]

        #expect(TouchedFilePolicy.mostRecent(
            paths,
            relativeTo: "/work/client",
            caseSensitive: false
        ) == ["Docs/Guide.md", "sources/AUTH.swift", "Tests/Login.swift"])
        #expect(TouchedFilePolicy.mostRecent(
            paths,
            relativeTo: "/work/client",
            caseSensitive: true
        ) == ["Docs/Guide.md", "sources/AUTH.swift", "Tests/Login.swift", "Sources/Auth.swift"])
    }

    @Test func countAndDonatedCharacterBudgetsAreHardBounds() {
        let many = (0..<100).map { "Sources/Feature\($0)/File\($0).swift" }
        let bounded = TouchedFilePolicy.mostRecent(
            many,
            relativeTo: "/work/client",
            caseSensitive: true
        )
        #expect(bounded.count == TouchedFilePolicy.maximumCount)
        let donatedLength = bounded.enumerated().reduce(0) { total, item in
            let basename = (item.element as NSString).lastPathComponent
            return total + (item.offset == 0 ? 0 : 1)
                + item.element.count + (basename == item.element ? 0 : 1 + basename.count)
        }
        #expect(donatedLength <= TouchedFilePolicy.maximumDonatedLength)

        let huge = (0..<10).map { "Sources/\(String(repeating: "x", count: 900))\($0).swift" }
        let characterBounded = TouchedFilePolicy.mostRecent(
            huge,
            relativeTo: "/work/client",
            caseSensitive: true
        )
        #expect(characterBounded.count < huge.count)
    }

    @Test func spotlightKeywordsAreOptInAndDeduplicated() {
        let disabled = SessionRecord.spotlightKeywords(
            projectName: "client",
            agent: .codex,
            gitBranch: "main",
            cwd: "/work/client",
            touchedFilePaths: ["Sources/client", "Tests/AuthTests.swift"],
            includeTouchedFiles: false
        )
        #expect(!disabled.contains("Sources/client"))
        #expect(!disabled.contains("AuthTests.swift"))

        let enabled = SessionRecord.spotlightKeywords(
            projectName: "client",
            agent: .codex,
            gitBranch: "main",
            cwd: "/work/client",
            touchedFilePaths: ["Sources/client", "Tests/AuthTests.swift"],
            includeTouchedFiles: true
        )
        #expect(enabled.contains("Sources/client"))
        #expect(enabled.contains("AuthTests.swift"))
        #expect(enabled.filter { $0 == "client" }.count == 1)
    }
}
