import SwiftUI

@main
struct SpotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Spotion", image: "MenuBarIcon") {
            MenuBarView()
        }
        Settings {
            SettingsView()
        }
    }
}
