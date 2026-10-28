// App entry point: declares the single main window and Settings (⌘,). The
// AppModel lives in the AppDelegate so quit handling can save through it.

import SwiftUI

@main
struct DocTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DocType", id: "main") {
            MainView()
                .environment(appDelegate.model)
        }
        .commands { AppMenus(model: appDelegate.model) }

        Settings {
            SettingsView(shortcuts: appDelegate.model.shortcuts)
        }
    }
}
