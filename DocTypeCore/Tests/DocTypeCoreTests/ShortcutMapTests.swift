// ShortcutMap: the user's shortcut changes over the defaults, conflicts,
// reserved shortcuts, and how they're stored.

import Testing
@testable import DocTypeCore

struct ShortcutMapTests {
    @Test func defaultsUntilChanged() {
        let map = ShortcutMap()
        #expect(map.shortcuts(for: .bold) == [.command("b")])
        #expect(map.command(for: .command("p", .shift)) == .showCommandPalette)  // a second default
        #expect(!map.isCustomized(.bold))
    }

    @Test func assigningReplacesTheCommandsShortcuts() throws {
        var map = ShortcutMap()
        try map.assign(.command("b", .control), to: .bold)
        #expect(map.shortcuts(for: .bold) == [.command("b", .control)])
        #expect(map.command(for: .command("b")) == nil)  // free now
        #expect(map.isCustomized(.bold))

        try map.assign(.command("p", .shift), to: .showCommandPalette)  // its own: allowed
        #expect(map.shortcuts(for: .showCommandPalette) == [.command("p", .shift)])
    }

    @Test func aShortcutInUseIsRefusedAndNothingChanges() {
        var map = ShortcutMap()
        #expect(throws: ShortcutMap.Refusal.usedBy(.italic)) { try map.assign(.command("i"), to: .bold) }
        #expect(throws: ShortcutMap.Refusal.reserved("Quit")) { try map.assign(.command("q"), to: .bold) }
        #expect(throws: ShortcutMap.Refusal.needsCommandOrControl) {
            try map.assign(Shortcut(.character("b"), [.option, .shift]), to: .bold)
        }
        #expect(map == ShortcutMap())
        #expect(ShortcutMap.Refusal.usedBy(.italic).message(for: .command("i")) == "⌘I is used by Italic.")
    }

    @Test func noDefaultIsReserved() {
        for command in CommandID.allCases {
            for shortcut in command.info.defaultShortcuts {
                #expect(ShortcutMap.reserved[shortcut] == nil, "\(command) uses \(shortcut.displayString)")
            }
        }
    }

    @Test func removingAndResetting() throws {
        var map = ShortcutMap()
        map.removeShortcuts(for: .bold)
        #expect(map.shortcuts(for: .bold).isEmpty)
        try map.reset(.bold)
        #expect(map.shortcuts(for: .bold) == [.command("b")])
        #expect(!map.isCustomized(.bold))

        // Assigning the defaults again isn't a change.
        try map.assign(.command("b", .control), to: .bold)
        try map.assign(.command("b"), to: .bold)
        #expect(map.overrides.isEmpty)
    }

    @Test func resetIsRefusedWhileAnotherCommandHasADefault() throws {
        var map = ShortcutMap()
        map.removeShortcuts(for: .bold)
        try map.assign(.command("b"), to: .italic)
        #expect(throws: ShortcutMap.Refusal.usedBy(.italic)) { try map.reset(.bold) }
        map.resetAll()
        #expect(map == ShortcutMap())
    }

    @Test func storageRoundTrips() throws {
        var map = ShortcutMap()
        try map.assign(.command("b", .control), to: .bold)
        try map.assign(.command("b"), to: .italic)  // Bold moved off ⌘B
        map.removeShortcuts(for: .link)
        try map.assign(Shortcut(.returnKey, [.command, .option]), to: .addRowBelow)
        #expect(map.storage["format.bold"] == ["ctrl+cmd+b"])
        #expect(map.storage["format.link"] == [])
        #expect(ShortcutMap(storage: map.storage) == map)
    }

    @Test func storageSkipsWhatItCantUse() {
        let map = ShortcutMap(storage: [
            "format.gone": ["cmd+j"],                 // no such command
            "format.bold": ["cmd+banana"],            // unreadable
            "format.italic": ["cmd+q"],               // reserved
            "format.inlineCode": ["cmd+n"],           // New Note has it
        ])
        #expect(map == ShortcutMap())
    }

    @Test func shortcutStorageStrings() {
        let shortcuts: [Shortcut] = [.command("p", .shift), Shortcut(.delete, .command), .command("+"), .command(" ", .control),
                                     Shortcut(.character("\t"), [.control, .option]), Shortcut(.returnKey, .command)]
        for shortcut in shortcuts {
            #expect(Shortcut(storageString: shortcut.storageString) == shortcut, "\(shortcut.storageString)")
        }
        #expect(Shortcut.command("p", .shift).storageString == "shift+cmd+p")
        #expect(Shortcut(storageString: "cmd+") == nil)
        #expect(Shortcut(storageString: "") == nil)
        #expect(Shortcut.command(" ", .control).displayString == "⌃⌘Space")
    }
}
