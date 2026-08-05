import AppKit
import ServiceManagement
import SwiftUI

/// LSUIElement app 唯一主动弹窗的场合：首次运行（无扫描缓存时）。
@MainActor
final class FirstRunWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Spotion"
        window.contentView = NSHostingView(rootView: FirstRunView())
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct FirstRunView: View {
    private var state = AppCoordinator.shared.uiState
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Spotion")
                .font(.largeTitle.bold())
            Text("Codex / Claude Code 会话，直接出现在 ⌘Space 里。")
                .foregroundStyle(.secondary)

            Divider()

            if state.isScanning {
                ProgressView("正在扫描会话并写入 Spotlight 索引…")
                    .progressViewStyle(.linear)
            } else {
                Label(
                    "已索引 \(state.codexCount) 个 Codex 会话、\(state.claudeCount) 个 Claude Code 会话",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 8) {
                    Text("试试看：")
                    Text("· 按 ⌘Space，输入项目名或会话关键词，回车即在终端中恢复会话")
                    Text("· 输入 \"New Codex\" 或 \"New Claude\"，内联填写 Prompt 直接新建会话")
                }
                .font(.callout)

                Text("搜不到结果？打开 系统设置 → Spotlight，确认允许显示 Spotion 的结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("打开 Spotlight 系统设置") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Toggle("登录时启动 Spotion（保持索引实时更新）", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    do {
                        if launchAtLogin {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Spacer()
        }
        .padding(24)
        .frame(width: 500, height: 380, alignment: .topLeading)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
