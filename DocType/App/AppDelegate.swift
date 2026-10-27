// AppKit lifecycle hooks SwiftUI doesn't offer: saving before quit and on deactivation.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.saveAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillResignActive(_ notification: Notification) {
        Task { await model.saveAll() }
    }
}
