// Shortcut settings: changes are kept in UserDefaults (so they survive a
// relaunch), refused changes say why, and recording turns key presses into
// shortcuts (Escape cancels, Delete removes).

import AppKit
import DocTypeCore
import Foundation
import Testing
@testable import DocType

@MainActor
struct ShortcutSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "DocTypeShortcutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    @Test func aChangeSurvivesARelaunch() {
        let store = defaults()
        let settings = ShortcutSettings(defaults: store)
        settings.assign(.command("b", .control), to: .bold)
        #expect(settings.shortcuts(for: .bold) == [.command("b", .control)])
        #expect(settings.message == nil)

        let relaunched = ShortcutSettings(defaults: store)
        #expect(relaunched.shortcuts(for: .bold) == [.command("b", .control)])
        relaunched.resetAll()
        #expect(ShortcutSettings(defaults: store).shortcuts(for: .bold) == [.command("b")])
    }

    @Test func aRefusedChangeKeepsTheOldShortcutAndSaysWhy() {
        let settings = ShortcutSettings(defaults: defaults())
        settings.assign(.command("i"), to: .bold)
        #expect(settings.shortcuts(for: .bold) == [.command("b")])
        #expect(settings.message == "⌘I is used by Italic.")
        settings.assign(.command("j"), to: .bold)
        #expect(settings.message == nil)

        settings.assign(.command("b"), to: .italic)  // free now
        settings.reset(.bold)
        #expect(settings.message == "Can't reset: ⌘B is used by Italic.")
    }

    @Test func recordingTurnsAKeyPressIntoTheShortcut() {
        let settings = ShortcutSettings(defaults: defaults())
        settings.startRecording(.bold)
        #expect(settings.record(key("b", code: 11, [.control, .command])))
        #expect(settings.shortcuts(for: .bold) == [.command("b", .control)])
        #expect(settings.recording == nil)

        settings.startRecording(.heading1)  // Shift with a digit stays the digit
        #expect(settings.record(key("!", code: 18, [.shift, .command])))
        #expect(settings.shortcuts(for: .heading1) == [.command("1", .shift)])

        settings.startRecording(.bold)  // Escape: nothing changes
        #expect(settings.record(key("\u{1b}", code: 53, [])))
        #expect(settings.shortcuts(for: .bold) == [.command("b", .control)])

        settings.startRecording(.bold)  // Delete: no shortcut
        #expect(settings.record(key("\u{7f}", code: 51, [])))
        #expect(settings.shortcuts(for: .bold).isEmpty)

        #expect(!settings.record(key("b", code: 11, [.command])))  // not recording: not taken
    }

    @Test func eventsMatchShortcutsByTheirKey() {
        #expect(Shortcut.command("p", .shift).matches(key("P", code: 35, [.shift, .command])))
        #expect(Shortcut(.returnKey, .command).matches(key("\r", code: 36, [.command])))
        #expect(!Shortcut.command("p").matches(key("P", code: 35, [.shift, .command])))
        #expect(Shortcut(event: key("\u{F700}", code: 126, [.command])) == nil)  // an arrow key
    }
}
