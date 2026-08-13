import SwiftUI

struct MenuBarView: View {
    private var state = AppCoordinator.shared.uiState
    private var updates = UpdateManager.shared.state

    var body: some View {
        if let version = updates.availableVersion {
            Button("有新版本 v\(version) — 立即更新") {
                UpdateManager.shared.checkForUpdates()
            }
            if let notes = updates.releaseNotesURL {
                Button("查看更新说明") {
                    NSWorkspace.shared.open(notes)
                }
            }
            Divider()
        }
        if state.pinned.isEmpty && state.recent.isEmpty {
            Text(state.isScanning ? "正在扫描会话…" : "尚未索引任何会话")
        }
        if !state.pinned.isEmpty {
            Section("Pinned") {
                ForEach(state.pinned, id: \.record.id) { item in
                    sessionButton(item)
                }
            }
        }
        if !state.recent.isEmpty {
            Section("Recent") {
                ForEach(state.recent, id: \.record.id) { item in
                    sessionButton(item)
                }
            }
        }
        Divider()
        Text(statsLine)
        if let error = state.lastError {
            Text("⚠︎ \(error)")
        }
        Button("Rescan Now") {
            Task { await AppCoordinator.shared.refreshAndApply() }
        }
        Button("Rebuild Spotlight Index") {
            Task { await AppCoordinator.shared.fullReindex() }
        }
        Button("Copy Scan Report") {
            Task {
                let report = await AppCoordinator.shared.store.scanReport()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
        Button("Check for Updates…") {
            UpdateManager.shared.checkForUpdates()
        }
        Divider()
        SettingsLink {
            Text("Settings…")
        }
        Button("Quit Spotion") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func sessionButton(_ item: TitledSession) -> some View {
        Button("\(item.title)") {
            Task {
                do { try await AppCoordinator.shared.openSession(id: item.record.id) }
                catch { AppCoordinator.shared.uiState.lastError = error.localizedDescription }
            }
        }
    }

    private var statsLine: String {
        var line = "Codex \(state.codexCount) · Claude \(state.claudeCount)"
        if state.parseFailures > 0 { line += " · \(state.parseFailures) 个解析失败" }
        return line
    }
}
