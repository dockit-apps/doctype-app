// Converts core Shortcuts to SwiftUI menu shortcuts and matches them against key events.

import AppKit
import DocTypeCore
import SwiftUI

extension Shortcut {
    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    /// True if `event` is this shortcut (used for alternate shortcuts menus can't show).
    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var pressed: Modifiers = []
        if flags.contains(.control) { pressed.insert(.control) }
        if flags.contains(.option) { pressed.insert(.option) }
        if flags.contains(.shift) { pressed.insert(.shift) }
        if flags.contains(.command) { pressed.insert(.command) }
        guard pressed == modifiers else { return false }
        switch key {
        case .character(let character):
            return event.charactersIgnoringModifiers?.lowercased() == String(character)
        case .delete:
            return event.keyCode == 51
        case .returnKey:
            return event.keyCode == 36
        }
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
