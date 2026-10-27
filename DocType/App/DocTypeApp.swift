// App entry point: declares the single main window. The AppModel lives in the
// AppDelegate so quit handling can save through it.

import SwiftUI

@main
struct DocTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DocType", id: "main") {
            MainView()
                .environment(appDelegate.model)
        }
    }
}
