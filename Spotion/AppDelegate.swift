import AppKit
import CoreSpotlight

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCoordinator.shared.start()
    }

    /// 旧式 Core Spotlight 点击路径的后备：Spotlight 结果未经 OpenIntent 而以
    /// CSSearchableItemActionType user activity 送达时，从 userInfo 取回条目 id。
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return false
        }
        Task {
            do {
                try await AppCoordinator.shared.openSession(id: id)
            } catch {
                NSLog("Spotion: open from user activity failed: %@", error.localizedDescription)
            }
        }
        return true
    }
}
