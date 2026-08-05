import ServiceManagement
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
    @State private var terminal = SpotionSettings.terminal
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("索引来源") {
                Toggle("Codex 会话（~/.codex）", isOn: $codexEnabled)
                    .onChange(of: codexEnabled) { applyAgents() }
                Toggle("Claude Code 会话（~/.claude）", isOn: $claudeEnabled)
                    .onChange(of: claudeEnabled) { applyAgents() }
            }
            Section("打开方式") {
                Picker("终端", selection: $terminal) {
                    ForEach(TerminalApp.allCases, id: \.rawValue) { app in
                        Text(app.displayName).tag(app)
                    }
                }
                .onChange(of: terminal) { SpotionSettings.terminal = terminal }
            }
            Section {
                Toggle("登录时启动 Spotion", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { applyLaunchAtLogin() }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
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
    @State private var checkTerm = ""
    @State private var checkResult: String?

    var body: some View {
        Form {
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
}
