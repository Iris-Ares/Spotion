import AppKit
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
        }
        .formStyle(.grouped)
    }
}

private struct IndexSettingsTab: View {
    private var state = AppCoordinator.shared.uiState
    @State private var searchLaterPrompts = SpotionSettings.searchLaterPrompts
    @State private var checkTerm = ""
    @State private var checkResult: String?

    var body: some View {
        Form {
            Section("Search") {
                Toggle("Search later prompts", isOn: $searchLaterPrompts)
                    .onChange(of: searchLaterPrompts) {
                        SpotionSettings.searchLaterPrompts = searchLaterPrompts
                        Task { await AppCoordinator.shared.refreshAndApply() }
                    }
                Text("Off by default. When enabled, up to five recent user prompts per session are stored only in the local macOS Spotlight index. Assistant, tool, thinking, command-wrapper, sidechain, and attachment content is excluded.")
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
                LabeledContent("Claude Code 会话", value: "\(state.claudeCount)")
                LabeledContent("解析失败", value: "\(state.parseFailures)")
                LabeledContent("上次索引", value: state.lastIndexed.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
                if let error = state.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
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
