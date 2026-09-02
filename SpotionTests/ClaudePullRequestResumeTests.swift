import Foundation
import Testing

@Suite struct ClaudePullRequestResumeTests {
    @Test func normalizesSupportedReferences() throws {
        let cases = [
            ("123", "123"),
            ("#123", "123"),
            ("  #00123\n", "123"),
            ("https://github.com/openai/codex/pull/123", "123"),
            ("https://GITHUB.com/Iris-Ares/Spotion/pull/18446744073709551615", "18446744073709551615"),
        ]
        for (raw, expected) in cases {
            #expect(try ClaudePullRequestResumePlan.normalize(raw) == expected)
        }
    }

    @Test func rejectsUnsupportedAndAmbiguousReferences() {
        let invalid = [
            "",
            "   ",
            "0",
            "#000",
            "-1",
            "+1",
            "123 trailing text",
            "18446744073709551616",
            "http://github.com/openai/codex/pull/123",
            "https://github.com/openai/codex",
            "https://github.com/openai/codex/issues/123",
            "https://github.com/openai/codex/pull/123/",
            "https://github.com/openai/codex/pull/123/files",
            "https://github.com/openai/codex/pull/123?diff=split",
            "https://github.com/openai/codex/pull/123#discussion",
            "https://github.com.evil.example/openai/codex/pull/123",
            "https://github.com@evil.example/openai/codex/pull/123",
            "https://user@github.com/openai/codex/pull/123",
            "https://github.com/openai%2Fcodex/repo/pull/123",
            "https://gitlab.com/openai/codex/-/merge_requests/123",
            "#1; echo owned",
        ]
        for raw in invalid {
            do {
                _ = try ClaudePullRequestResumePlan.normalize(raw)
                Issue.record("Expected rejection for \(raw)")
            } catch {
                #expect(error as? ClaudePullRequestResumeError == .invalidReference)
            }
        }
    }

    @Test func buildsQuotedTerminalOnlyPlan() throws {
        let cwd = "/tmp/Repo O'Brien/资料 & notes"
        let binary = "/tmp/Claude B'in/claude;$(bad)"
        for terminal in TerminalApp.allCases {
            let plan = try ClaudePullRequestResumePlan.make(
                rawReference: "https://github.com/openai/codex/pull/123",
                cwd: cwd,
                claudeEnabled: true,
                terminal: terminal,
                resolveBinary: { binary },
                directoryExists: { $0 == cwd }
            )
            #expect(plan.normalizedReference == "123")
            #expect(plan.cwd == cwd)
            #expect(plan.terminal == terminal)
            #expect(
                plan.shellCommand
                    == "cd '/tmp/Repo O'\\''Brien/资料 & notes' && exec '/tmp/Claude B'\\''in/claude;$(bad)' --from-pr '123'"
            )
            #expect(!plan.shellCommand.contains("--continue"))
            #expect(!plan.shellCommand.contains("--last"))
            #expect(!plan.shellCommand.contains(" -- "))
        }
    }

    @Test func preflightFailsBeforeCommandDispatch() {
        var resolvedBinary = false
        do {
            _ = try ClaudePullRequestResumePlan.make(
                rawReference: "123",
                cwd: "/tmp/project",
                claudeEnabled: false,
                terminal: .terminal,
                resolveBinary: { resolvedBinary = true; return "/bin/claude" },
                directoryExists: { _ in true }
            )
            Issue.record("Expected disabled Claude to fail")
        } catch {
            #expect(error as? ClaudePullRequestResumeError == .claudeDisabled)
        }
        #expect(!resolvedBinary)

        do {
            _ = try ClaudePullRequestResumePlan.make(
                rawReference: "123",
                cwd: "/removed/project",
                claudeEnabled: true,
                terminal: .ghostty,
                resolveBinary: { resolvedBinary = true; return "/bin/claude" },
                directoryExists: { _ in false }
            )
            Issue.record("Expected a removed project to fail")
        } catch {
            #expect(error as? ClaudePullRequestResumeError == .missingDirectory("/removed/project"))
        }
        #expect(!resolvedBinary)
    }

    @Test func missingBinaryErrorIsPreserved() {
        enum StubError: Error, Equatable { case missingBinary }
        do {
            _ = try ClaudePullRequestResumePlan.make(
                rawReference: "#123",
                cwd: "/tmp/project",
                claudeEnabled: true,
                terminal: .terminal,
                resolveBinary: { throw StubError.missingBinary },
                directoryExists: { _ in true }
            )
            Issue.record("Expected binary resolution to fail")
        } catch {
            #expect(error as? StubError == .missingBinary)
        }
    }
}
