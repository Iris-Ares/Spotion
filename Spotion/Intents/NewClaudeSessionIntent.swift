import AppIntents

struct NewClaudeSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Claude Session"
    static let description = IntentDescription(
        "Start a new Claude Code session in your terminal.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true))
    var prompt: String

    @Parameter(title: "Project")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start Claude Code with \(\.$prompt)") {
            \.$project
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cwd = project?.id ?? SpotionSettings.defaultNewSessionDir
        try await TerminalLauncher.shared.startNew(agent: .claude, prompt: prompt, cwd: cwd)
        return .result(dialog: "Claude Code 会话已在 \((cwd as NSString).lastPathComponent) 启动")
    }
}
