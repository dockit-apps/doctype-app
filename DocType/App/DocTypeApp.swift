// App entry point: declares the single main window.

import SwiftUI

@main
struct DocTypeApp: App {
    var body: some Scene {
        Window("DocType", id: "main") {
            MainView()
        }
    }
}
