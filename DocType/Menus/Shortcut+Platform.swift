// Converts core Shortcuts to SwiftUI menu shortcuts and matches them against key events.

import AppKit
import DocTypeCore
import SwiftUI

extension Shortcut {
    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    /// The shortcut a key press makes, or nil for a key it can't name (F-keys, arrows).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        switch event.keyCode {
        case 51: self.init(.delete, modifiers)
        case 36, 76: self.init(.returnKey, modifiers)
        default:
            // The key's own character: charactersIgnoringModifiers still applies
            // Shift (⇧⌘1 would read as "!").
            let plain = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
            guard let character = plain?.lowercased().first, let scalar = character.unicodeScalars.first else { return nil }
            // Tab is a control character too, but a key with a name; arrows and
            // F-keys come as private-use characters.
            let isControl = CharacterSet.controlCharacters.contains(scalar) || (0xF700...0xF8FF).contains(scalar.value)
            guard character == "\t" || !isControl else { return nil }
            self.init(.character(character), modifiers)
        }
    }

    /// True if `event` is this shortcut (used for alternate shortcuts menus can't show).
    func matches(_ event: NSEvent) -> Bool {
        Shortcut(event: event) == self
    }

    private var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let character): KeyEquivalent(character)
        case .delete: .delete
        case .returnKey: .return
        }
    }

    private var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }
}
