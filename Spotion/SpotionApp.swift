import SwiftUI

@main
struct SpotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Spotion", systemImage: "text.magnifyingglass") {
            MenuBarView()
        }
        Settings {
            SettingsView()
        }
    }
}
