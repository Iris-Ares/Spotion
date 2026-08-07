import AppKit
import Sparkle

/// Update availability surfaced to the menu bar. Set only by scheduled
/// (gentle-reminder) checks; user-initiated checks go straight to Sparkle's
/// standard UI and never populate this.
@MainActor
@Observable
final class UpdateState {
    var availableVersion: String?
    var releaseNotesURL: URL?
}

/// Owns the Sparkle updater for the app. Scheduled checks are silent and only
/// light up menu rows via `UpdateState`; the actual download/install/relaunch
/// flow (with progress and failure UI) is Sparkle's standard user driver,
/// entered through `checkForUpdates()`.
@MainActor
final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    let state = UpdateState()
    private var controller: SPUStandardUpdaterController!

    var updater: SPUUpdater { controller.updater }

    private override init() {
        super.init()
        // startingUpdater: true only schedules; network checks run off-main
        // inside Sparkle and never block launch.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    /// Hands off to Sparkle's standard UI: check → download → install → relaunch.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private func clearReminder() {
        state.availableVersion = nil
        state.releaseNotesURL = nil
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    #if DEBUG
    /// Test hook for exercising the full update loop against a local feed:
    /// `defaults write com.ares.spotion feedURLOverride http://localhost:8000/appcast.xml`
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "feedURLOverride")
    }
    #endif
}

// Gentle scheduled update reminders: never pop windows from a background
// check on this LSUIElement app — publish to UpdateState and let the menu
// show it instead. The standard user driver calls these on the main thread;
// @preconcurrency conformance asserts that at runtime.
extension UpdateManager: @preconcurrency SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // Sparkle handles user-initiated checks itself; only scheduled checks
        // (which we declined above) need the menu reminder.
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        self.state.availableVersion = version
        self.state.releaseNotesURL = update.fullReleaseNotesURL
            ?? update.releaseNotesURL
            ?? URL(string: "https://github.com/Iris-Ares/Spotion/releases/tag/v\(version)")
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearReminder()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearReminder()
    }
}
