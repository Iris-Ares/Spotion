import SwiftUI

struct MenuBarView: View {
    private var state = AppCoordinator.shared.uiState

    var body: some View {
        if state.recent.isEmpty {
            Text(state.isScanning ? "正在扫描会话…" : "尚未索引任何会话")
        } else {
            ForEach(state.recent, id: \.record.id) { item in
                Button("\(item.title)") {
                    Task { try? await AppCoordinator.shared.openSession(id: item.record.id) }
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
        Divider()
        SettingsLink {
            Text("Settings…")
        }
        Button("Quit Spotion") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statsLine: String {
        var line = "Codex \(state.codexCount) · Claude \(state.claudeCount)"
        if state.parseFailures > 0 { line += " · \(state.parseFailures) 个解析失败" }
        return line
    }
}
