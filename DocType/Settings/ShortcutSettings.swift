// The user's keyboard shortcuts: core ShortcutMap kept in UserDefaults, and
// recording a new one in Settings. Menus, palette hints and the key monitor
// read `map`, so a change shows up everywhere at once.

import AppKit
import DocTypeCore
import Observation

@Observable
final class ShortcutSettings {
    static let defaultsKey = "shortcutOverrides"

    private(set) var map: ShortcutMap
    /// The command whose new shortcut is being typed in Settings. Keys go
    /// there then, not to commands or menus.
    private(set) var recording: CommandID?
    /// Why the last change was refused, shown in Settings.
    private(set) var message: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var monitor: Any?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
        map = ShortcutMap(storage: stored)
    }

    func shortcuts(for command: CommandID) -> [Shortcut] {
        map.shortcuts(for: command)
    }

    func assign(_ shortcut: Shortcut, to command: CommandID) {
        change { try $0.assign(shortcut, to: command) } describing: { $0.message(for: shortcut) }
    }

    func removeShortcuts(for command: CommandID) {
        change { $0.removeShortcuts(for: command) } describing: { _ in "" }
    }

    func reset(_ command: CommandID) {
        let shortcut = command.info.defaultShortcuts.first
        change { try $0.reset(command) } describing: { refusal in
            shortcut.map { "Can't reset: \(refusal.message(for: $0))" } ?? ""
        }
    }

    func resetAll() {
        change { $0.resetAll() } describing: { _ in "" }
    }

    /// Applies `edit` to the map and saves it; a refusal leaves everything as it
    /// was and plays the alert sound.
    private func change(_ edit: (inout ShortcutMap) throws -> Void,
                        describing describe: (ShortcutMap.Refusal) -> String) {
        var changed = map
        do {
            try edit(&changed)
        } catch {
            message = (error as? ShortcutMap.Refusal).map(describe)
            NSSound.beep()  // the system alert sound: a refusal is heard, not only shown
            return
        }
        message = nil
        guard changed != map else { return }
        map = changed
        defaults.set(map.storage, forKey: Self.defaultsKey)
    }

    // MARK: - Recording

    /// The next key press becomes `command`'s shortcut. Escape cancels;
    /// Delete on its own removes the shortcut.
    func startRecording(_ command: CommandID) {
        stopRecording()
        recording = command
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return record(event) ? nil : event
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    /// Handles a key press while recording; true if it was used.
    func record(_ event: NSEvent) -> Bool {
        guard let command = recording else { return false }
        defer { stopRecording() }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, flags.isEmpty { return true }  // Escape: cancel
        if event.keyCode == 51, flags.isEmpty {  // Delete: no shortcut
            removeShortcuts(for: command)
            return true
        }
        guard let shortcut = Shortcut(event: event) else {
            NSSound.beep()
            return true
        }
        assign(shortcut, to: command)
        return true
    }
}
