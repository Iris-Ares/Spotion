import AppIntents

/// Spotlight 内联新建 Codex 会话：必填 prompt 出现在 parameterSummary（Spotlight 可见性硬条件）。
struct NewCodexSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Codex Session"
    static let description = IntentDescription(
        "Start a new Codex CLI session in your terminal.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true))
    var prompt: String

    @Parameter(title: "Project")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start Codex with \(\.$prompt)") {
            \.$project
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cwd = project?.id ?? SpotionSettings.defaultNewSessionDir
        try await TerminalLauncher.shared.startNew(agent: .codex, prompt: prompt, cwd: cwd)
        return .result(dialog: "Codex 会话已在 \((cwd as NSString).lastPathComponent) 启动")
    }
}
