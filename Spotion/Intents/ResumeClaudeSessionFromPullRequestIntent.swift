import AppIntents

struct ResumeClaudeSessionFromPullRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Claude Session from Pull Request"
    static let description = IntentDescription(
        "Hand a GitHub pull request to Claude Code's linked-session lookup in your terminal.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Project")
    var project: ProjectEntity

    @Parameter(title: "Pull Request")
    var pullRequest: String

    static var parameterSummary: some ParameterSummary {
        Summary("Resume Claude session from PR \(\.$pullRequest) in \(\.$project)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reference = try await TerminalLauncher.shared.resumeClaude(
            fromPullRequest: pullRequest,
            cwd: project.id
        )
        return .result(
            dialog: "已将 PR #\(reference) 交给终端中的 Claude Code；是否找到并恢复关联会话以 Claude Code 输出为准。"
        )
    }
}
