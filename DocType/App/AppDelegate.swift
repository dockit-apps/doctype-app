// AppKit lifecycle hooks SwiftUI doesn't offer: saving before quit and on deactivation.

import AppKit
import DocTypeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // By default AppKit catches Objective-C exceptions and carries on. When one
        // passes through Swift async code, the concurrency runtime is left corrupted
        // and the app later crashes somewhere unrelated or hangs. Crash right away
        // instead, with the real cause in the report (autosave keeps the loss to ~1 s).
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menus can show only one shortcut per item; extra ones (⇧⌘P for the
        // palette) are caught here and run the same command.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            for command in CommandID.allCases {
                if command.info.defaultShortcuts.dropFirst().contains(where: { $0.matches(event) }) {
                    model.commands.run(command)
                    return nil
                }
            }
            return event
        }
    }

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
