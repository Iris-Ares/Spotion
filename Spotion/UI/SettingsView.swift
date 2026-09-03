import ServiceManagement
import Sparkle
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            IndexSettingsTab()
                .tabItem { Label("Index", systemImage: "magnifyingglass") }
        }
        .frame(width: 480, height: 360)
    }
}

private struct GeneralSettingsTab: View {
    @State private var codexEnabled = SpotionSettings.enabledAgents.contains(.codex)
    @State private var claudeEnabled = SpotionSettings.enabledAgents.contains(.claude)
    @State private var codexTarget = SpotionSettings.launchTarget(for: .codex)
    @State private var claudeTarget = SpotionSettings.launchTarget(for: .claude)
    @State private var terminal = SpotionSettings.terminal
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var missingNativeApps: [AgentKind] = []
    @State private var autoCheckUpdates = UpdateManager.shared.updater.automaticallyChecksForUpdates
    @State private var canCheckForUpdates = true

    var body: some View {
        Form {
            Section("索引来源") {
                Toggle("Codex 会话（~/.codex）", isOn: $codexEnabled)
                    .onChange(of: codexEnabled) { applyAgents() }
                Toggle("Claude Code 会话（~/.claude）", isOn: $claudeEnabled)
                    .onChange(of: claudeEnabled) { applyAgents() }
            }
            Section("打开方式") {
                Picker("Codex 会话", selection: $codexTarget) {
                    ForEach(LaunchTarget.allCases, id: \.rawValue) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .onChange(of: codexTarget) {
                    SpotionSettings.setLaunchTarget(codexTarget, for: .codex)
                    refreshNativeAvailability()
                }
                Picker("Claude Code 会话", selection: $claudeTarget) {
                    ForEach(LaunchTarget.allCases, id: \.rawValue) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .onChange(of: claudeTarget) {
                    SpotionSettings.setLaunchTarget(claudeTarget, for: .claude)
                    refreshNativeAvailability()
                }
                Picker("终端", selection: $terminal) {
                    ForEach(TerminalApp.allCases, id: \.rawValue) { app in
                        Text(app.displayName).tag(app)
                    }
                }
                .onChange(of: terminal) { SpotionSettings.terminal = terminal }
                ForEach(missingNativeApps, id: \.rawValue) { agent in
                    Text("未检测到能打开 \(agent.displayName) 会话的桌面应用（\(NativeAppLink.scheme(for: agent))://），该来源的会话将无法打开")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if claudeTarget == .nativeApp {
                    Text("Claude 桌面版以「导入副本」方式打开会话：侧边栏会多一条由 App 自行命名的同内容会话，且导入会精简原始记录文件（Claude.app 行为）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if codexTarget == .nativeApp || claudeTarget == .nativeApp {
                    Text("新建会话（Quick Create）始终在终端启动")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("登录时启动 Spotion", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { applyLaunchAtLogin() }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("软件更新") {
                LabeledContent("当前版本", value: appVersion)
                Toggle("自动检查更新", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) {
                        UpdateManager.shared.updater.automaticallyChecksForUpdates = autoCheckUpdates
                    }
                Button("Check for Updates…") { UpdateManager.shared.checkForUpdates() }
                    .disabled(!canCheckForUpdates)
                    .onReceive(UpdateManager.shared.updater.publisher(for: \.canCheckForUpdates)) {
                        canCheckForUpdates = $0
                    }
                Text("更新来自 GitHub Releases（github.com/Iris-Ares/Spotion）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshNativeAvailability() }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func target(for agent: AgentKind) -> LaunchTarget {
        switch agent {
        case .codex: codexTarget
        case .claude: claudeTarget
        }
    }

    private func refreshNativeAvailability() {
        missingNativeApps = AgentKind.allCases.filter {
            target(for: $0) == .nativeApp && NativeAppLauncher.shared.installedAppURL(for: $0) == nil
        }
    }

    private func applyAgents() {
        var agents = Set<AgentKind>()
        if codexEnabled { agents.insert(.codex) }
        if claudeEnabled { agents.insert(.claude) }
        SpotionSettings.enabledAgents = agents
        Task { await AppCoordinator.shared.agentToggled() }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct AdvancedSettingsTab: View {
    @State private var codexPath = SpotionSettings.codexPathOverride ?? ""
    @State private var claudePath = SpotionSettings.claudePathOverride ?? ""
    @State private var defaultDir = SpotionSettings.defaultNewSessionDir
    @State private var savedProjects: [SavedProject] = []
    @State private var savedProjectMessage: String?

    var body: some View {
        Form {
            Section("可执行文件路径覆盖（留空为自动探测）") {
                TextField("codex", text: $codexPath, prompt: Text("/Applications/ChatGPT.app/Contents/Resources/codex"))
                    .onChange(of: codexPath) { SpotionSettings.codexPathOverride = codexPath }
                TextField("claude", text: $claudePath, prompt: Text("~/.local/bin/claude"))
                    .onChange(of: claudePath) { SpotionSettings.claudePathOverride = claudePath }
            }
            Section("Quick Create 默认目录（未选 Project 参数时）") {
                TextField("目录", text: $defaultDir)
                    .onChange(of: defaultDir) { SpotionSettings.defaultNewSessionDir = defaultDir }
            }
            Section("Saved Quick Create projects") {
                if savedProjects.isEmpty {
                    Text("No saved projects")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(savedProjects.enumerated()), id: \.element.id) { index, project in
                    HStack {
                        Image(systemName: project.isAvailable ? "folder" : "exclamationmark.triangle")
                            .foregroundStyle(project.isAvailable ? Color.secondary : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                            Text(project.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !project.isAvailable {
                                Text("Unavailable — Quick Create will not fall back to another directory")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button {
                            moveSavedProject(from: index, to: index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("Move up")
                        Button {
                            moveSavedProject(from: index, to: index + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == savedProjects.count - 1)
                        .help("Move down")
                        Button(role: .destructive) {
                            removeSavedProject(project.path)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove saved project")
                    }
                }
                Button("Add Folder…") { chooseSavedProject() }
                Text("Saved folders appear first for both Codex and Claude Quick Create. Removing one does not delete files or indexed sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let savedProjectMessage {
                    Text(savedProjectMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadSavedProjects() }
    }

    private func chooseSavedProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Save Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try AppCoordinator.shared.addSavedProject(path: url.path) }
    }

    private func removeSavedProject(_ path: String) {
        perform { try AppCoordinator.shared.removeSavedProject(path: path) }
    }

    private func moveSavedProject(from source: Int, to destination: Int) {
        perform { try AppCoordinator.shared.moveSavedProject(from: source, to: destination) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            reloadSavedProjects()
        } catch {
            savedProjectMessage = error.localizedDescription
        }
    }

    private func reloadSavedProjects() {
        savedProjects = AppCoordinator.shared.savedProjects()
        savedProjectMessage = AppCoordinator.shared.savedProjectStorageWarning()
    }
}

private struct IndexSettingsTab: View {
    private var state = AppCoordinator.shared.uiState
    @State private var searchLaterPrompts = SpotionSettings.searchLaterPrompts
    @State private var searchAssistantReplies = SpotionSettings.searchAssistantReplies
    @State private var historyWindow = SpotionSettings.spotlightHistoryWindow
    @State private var searchTouchedFiles = SpotionSettings.searchTouchedFiles
    @State private var includeArchivedCodex = SpotionSettings.includeArchivedCodexSessions
    @State private var checkTerm = ""
    @State private var checkResult: String?

    var body: some View {
        Form {
            Section("Search") {
                Picker("Spotlight history window", selection: $historyWindow) {
                    ForEach(SpotlightHistoryWindow.allCases, id: \.rawValue) { window in
                        Text(window.displayName).tag(window)
                    }
                }
                .onChange(of: historyWindow) {
                    SpotionSettings.spotlightHistoryWindow = historyWindow
                    Task { await AppCoordinator.shared.refreshAndApply() }
                }
                Text("Limits Spotion visibility only. Codex and Claude history, archives, and source files are never deleted or changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Search later prompts", isOn: $searchLaterPrompts)
                    .onChange(of: searchLaterPrompts) {
                        SpotionSettings.searchLaterPrompts = searchLaterPrompts
                        Task { await AppCoordinator.shared.refreshAndApply() }
                    }
                Text("Off by default. When enabled, up to five recent user prompts per session are stored only in the local macOS Spotlight index. Assistant, tool, thinking, command-wrapper, sidechain, and attachment content is excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Search recent assistant replies", isOn: $searchAssistantReplies)
                    .onChange(of: searchAssistantReplies) {
                        SpotionSettings.searchAssistantReplies = searchAssistantReplies
                        Task { await AppCoordinator.shared.refreshAndApply() }
                    }
                Text("Off by default. Donates up to five recent visible assistant text snippets only to the local macOS Spotlight index. Thinking, tools, system content, sidechains, attachments, and persisted Spotion state are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Search files touched", isOn: $searchTouchedFiles)
                    .onChange(of: searchTouchedFiles) {
                        SpotionSettings.searchTouchedFiles = searchTouchedFiles
                        Task { await AppCoordinator.shared.refreshAndApply() }
                    }
                Text("Off by default. Extracts only a bounded set of project-relative paths from recognized Read, Write, and Edit tool inputs. Shell commands, patches, prose, tool output, attachments, and paths outside the session project are never indexed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Include archived Codex sessions", isOn: $includeArchivedCodex)
                    .onChange(of: includeArchivedCodex) {
                        SpotionSettings.includeArchivedCodexSessions = includeArchivedCodex
                        Task { await AppCoordinator.shared.refreshAndApply() }
                    }
                Text("Off by default. Archived results are visibly labeled and require confirmation before Spotion asks Codex to unarchive and open them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Hidden sessions") {
                if state.hiddenSessions.isEmpty {
                    Text("No sessions are hidden from Spotion.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.hiddenSessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                Text("\(session.agent.displayName) · \(session.projectName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                Task { @MainActor in
                                    do {
                                        try await AppCoordinator.shared.restoreSession(id: session.id)
                                    } catch {
                                        AppCoordinator.shared.uiState.lastError = error.localizedDescription
                                    }
                                }
                            }
                        }
                    }
                }
                Text("Hiding affects Spotion only. It never deletes, archives, renames, or edits the Codex or Claude source session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Excluded projects") {
                HStack {
                    Button("Add Folder…") { chooseExcludedFolder() }
                    Menu("Add Recent Project") {
                        if state.availableProjects.isEmpty {
                            Text("No observed projects")
                        } else {
                            ForEach(state.availableProjects, id: \.cwd) { project in
                                Button("\(project.name) — \(project.cwd)") {
                                    addExclusion(project.cwd)
                                }
                            }
                        }
                    }
                }
                if state.excludedProjects.isEmpty {
                    Text("No projects are excluded from Spotion.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.excludedProjects) { exclusion in
                        HStack {
                            Text(exclusion.path)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Remove") { removeExclusion(exclusion.path) }
                        }
                    }
                }
                Text("Spotion excludes sessions whose working directory is this folder or a descendant. This does not change project files, agent transcripts, agent settings, or macOS Spotlight Privacy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("状态") {
                LabeledContent("Codex 会话", value: "\(state.codexCount)")
                if state.archivedCodexCount > 0 {
                    LabeledContent("Archived Codex", value: "\(state.archivedCodexCount)")
                }
                if state.archiveConflicts > 0 {
                    LabeledContent("Active/archive conflicts", value: "\(state.archiveConflicts)")
                }
                LabeledContent("Claude Code 会话", value: "\(state.claudeCount)")
                LabeledContent("解析失败", value: "\(state.parseFailures)")
                LabeledContent("Spotlight 可见", value: "\(state.visibleCount) / \(state.totalCount)")
                LabeledContent("上次索引", value: state.lastIndexed.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
                if let error = state.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                ForEach(state.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("维护") {
                HStack {
                    Button("Rescan Now") { Task { await AppCoordinator.shared.refreshAndApply() } }
                    Button("Rebuild Index") { Task { await AppCoordinator.shared.fullReindex() } }
                }
            }
            Section("索引自检（CSUserQuery 直查，不经过 Spotlight UI）") {
                HStack {
                    TextField("搜索词（如某个项目名）", text: $checkTerm)
                    Button("Check") {
                        let term = checkTerm
                        Task { @MainActor in
                            let hits = await AppCoordinator.shared.selfCheck(term: term)
                            checkResult = hits > 0
                                ? "命中 \(hits) 条——索引正常；若 Spotlight 搜不到，检查系统设置里的 Spotlight 开关"
                                : "0 命中——索引未写入，试试 Rebuild Index"
                        }
                    }
                    .disabled(checkTerm.isEmpty)
                }
                if let checkResult {
                    Text(checkResult).font(.caption)
                }
                Button("打开 Spotlight 系统设置") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseExcludedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Exclude"
        panel.message = "Choose a project folder to exclude from Spotion only."
        if panel.runModal() == .OK, let path = panel.url?.path {
            addExclusion(path)
        }
    }

    private func addExclusion(_ path: String) {
        Task { @MainActor in
            do {
                try await AppCoordinator.shared.addProjectExclusion(path: path)
            } catch {
                AppCoordinator.shared.uiState.lastError = error.localizedDescription
            }
        }
    }

    private func removeExclusion(_ path: String) {
        Task { @MainActor in
            do {
                try await AppCoordinator.shared.removeProjectExclusion(path: path)
            } catch {
                AppCoordinator.shared.uiState.lastError = error.localizedDescription
            }
        }
    }
}
