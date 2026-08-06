import AppKit
import CoreSpotlight

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCoordinator.shared.start()
    }

    /// Fallback for the legacy Core Spotlight click path: when a Spotlight
    /// result arrives as a CSSearchableItemActionType user activity instead of
    /// going through OpenIntent, recover the item id from userInfo.
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
