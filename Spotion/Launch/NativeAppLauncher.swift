import AppKit
import Foundation

/// Opens a session in its agent's desktop app via deep link. The handler app
/// is resolved through LaunchServices (urlForApplication(toOpen:)) — never a
/// hardcoded path, since the Codex/ChatGPT install location varies.
/// Responsibility ends at a successful handoff: in-app failures (missing
/// transcript, expired sign-in) are surfaced by the desktop app's own UI, so
/// no attempt is made to verify the session actually appeared there.
final class NativeAppLauncher: Sendable {
    static let shared = NativeAppLauncher()

    struct LaunchError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// nil → no app registered for the agent's scheme. Also drives the
    /// availability hint in Settings.
    func installedAppURL(for agent: AgentKind) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: NativeAppLink.probeURL(for: agent))
    }

    /// Returns the handler app's display name for the intent dialog.
    /// Unlike the CLI path there is no cwd-existence guard: the desktop apps
    /// locate the transcript by uuid themselves, so a session whose directory
    /// was deleted is still openable here.
    @MainActor
    func resume(_ record: SessionRecord) async throws -> String {
        guard let url = NativeAppLink.url(agent: record.agent, sessionID: record.sessionID) else {
            throw LaunchError(
                message: "无法为该会话生成桌面应用链接（会话 ID 不是标准 UUID：\(record.sessionID)）。可在 Spotion 设置里把打开方式改回终端 CLI。")
        }
        guard let appURL = installedAppURL(for: record.agent) else {
            throw LaunchError(
                message: "未找到能处理 \(NativeAppLink.scheme(for: record.agent)):// 链接的应用。请先安装 \(NativeAppLink.appHint(for: record.agent))，或在 Spotion 设置里把打开方式改回终端 CLI。")
        }
        // Localized handler name ("Claude" / "ChatGPT"), truthful whatever
        // app actually claims the scheme.
        let appName = FileManager.default.displayName(atPath: appURL.path)
        do {
            // Completion-handler variant: the async import returns a
            // non-Sendable NSRunningApplication we would only discard.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            throw LaunchError(message: "\(appName) 打开失败：\(error.localizedDescription)")
        }
        return appName
    }
}
