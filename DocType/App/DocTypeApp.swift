// App entry point: owns the AppModel and declares the single main window.

import SwiftUI

@main
struct DocTypeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("DocType", id: "main") {
            MainView()
                .environment(model)
        }
    }
}
