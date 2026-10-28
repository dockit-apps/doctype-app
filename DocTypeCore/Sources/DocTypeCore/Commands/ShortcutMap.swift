// Which shortcuts run which command: each command's defaults (CommandID.info)
// with the user's changes on top. Menus, palette hints and the key monitor all
// read from one map, so a change shows up everywhere at once.
//
// Rules: a shortcut needs ⌘ or ⌃ (without them it would type a character);
// one in use (by another command, or reserved by macOS or the standard Edit
// menu) is never taken: the change is refused and says who has it, so a
// binding never disappears from a command without the user seeing it.
// Resetting a command to its defaults follows the same rule. Reset All always
// works. Alternatives considered: letting the new binding win and silently
// unbinding the other command (what some editors do; easy to lose a shortcut
// without noticing), or allowing duplicates with a warning (then which one runs
// depends on menu order).

public struct ShortcutMap: Equatable, Sendable {
    /// Commands whose shortcuts differ from their defaults; an empty list means none.
    public private(set) var overrides: [CommandID: [Shortcut]]

    public init(overrides: [CommandID: [Shortcut]] = [:]) {
        self.overrides = overrides
    }

    /// Why a shortcut can't be assigned.
    public enum Refusal: Error, Equatable, Sendable {
        /// Needs ⌘ or ⌃.
        case needsCommandOrControl
        /// Runs another command.
        case usedBy(CommandID)
        /// macOS or the standard menus use it (the name says for what).
        case reserved(String)

        /// For the settings pane, e.g. "⌘B is used by Bold."
        public func message(for shortcut: Shortcut) -> String {
            switch self {
            case .needsCommandOrControl: "A shortcut needs ⌘ or ⌃."
            case .usedBy(let command): "\(shortcut.displayString) is used by \(command.title)."
            case .reserved(let name): "\(shortcut.displayString) is used by \(name)."
            }
        }
    }

    /// Shortcuts macOS or the standard app and Edit menus own.
    public static let reserved: [Shortcut: String] = [
        .command("q"): "Quit", .command("w"): "Close Window", .command("h"): "Hide DocType",
        .command("h", .option): "Hide Others", .command("m"): "Minimize", .command(","): "Settings",
        .command("z"): "Undo", .command("z", .shift): "Redo", .command("x"): "Cut", .command("c"): "Copy",
        .command("v"): "Paste", .command("v", [.option, .shift]): "Paste and Match Style",
        .command("a"): "Select All", .command("f", .control): "Full Screen", .command("/", .shift): "Help",
        .command(" "): "Spotlight", .command(" ", .control): "Emoji & Symbols", .command("\t"): "the App Switcher",
        .command("`"): "Cycle Windows", .command("3", .shift): "Screenshot", .command("4", .shift): "Screenshot",
        .command("5", .shift): "Screenshot",
    ]

    /// The command's shortcuts; the first is the one menus show.
    public func shortcuts(for command: CommandID) -> [Shortcut] {
        overrides[command] ?? command.info.defaultShortcuts
    }

    /// The command `shortcut` runs, if any.
    public func command(for shortcut: Shortcut) -> CommandID? {
        CommandID.allCases.first { shortcuts(for: $0).contains(shortcut) }
    }

    public func isCustomized(_ command: CommandID) -> Bool {
        overrides[command] != nil
    }

    /// Why `shortcut` can't run `command`, or nil if it can.
    public func refusal(for shortcut: Shortcut, assigningTo command: CommandID) -> Refusal? {
        guard shortcut.modifiers.contains(.command) || shortcut.modifiers.contains(.control) else {
            return .needsCommandOrControl
        }
        if let name = Self.reserved[shortcut] { return .reserved(name) }
        if let owner = self.command(for: shortcut), owner != command { return .usedBy(owner) }
        return nil
    }

    /// Makes `shortcut` the command's only shortcut, unless it's refused.
    public mutating func assign(_ shortcut: Shortcut, to command: CommandID) throws(Refusal) {
        if let refusal = refusal(for: shortcut, assigningTo: command) { throw refusal }
        setShortcuts([shortcut], for: command)
    }

    /// Leaves the command without a shortcut (palette and menu still run it).
    public mutating func removeShortcuts(for command: CommandID) {
        setShortcuts([], for: command)
    }

    /// Back to the command's default shortcuts, unless another command has one of them now.
    public mutating func reset(_ command: CommandID) throws(Refusal) {
        for shortcut in command.info.defaultShortcuts {
            if let owner = self.command(for: shortcut), owner != command { throw .usedBy(owner) }
        }
        overrides[command] = nil
    }

    public mutating func resetAll() {
        overrides = [:]
    }

    private mutating func setShortcuts(_ shortcuts: [Shortcut], for command: CommandID) {
        overrides[command] = shortcuts == command.info.defaultShortcuts ? nil : shortcuts
    }

    // MARK: - Storage

    /// The overrides as plain values for settings: command identifier → shortcut strings.
    public var storage: [String: [String]] {
        Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.map(\.storageString)) })
    }

    /// Reads `storage`, skipping commands that no longer exist and shortcuts it
    /// can't read, and any that would clash (e.g. a new default took it): those
    /// commands keep their defaults.
    public init(storage: [String: [String]]) {
        var map = ShortcutMap()
        for (identifier, strings) in storage {
            guard let command = CommandID(rawValue: identifier) else { continue }
            let shortcuts = strings.compactMap(Shortcut.init(storageString:))
            guard shortcuts.count == strings.count else { continue }
            map.setShortcuts(shortcuts, for: command)
        }
        // Checked all together (Italic may take ⌘B because Bold moved): drop a
        // clashing override until none clash. Dropping one brings its defaults
        // back, which may clash with another override in the next pass.
        var dropped = true
        while dropped {
            dropped = false
            for command in CommandID.allCases where map.overrides[command] != nil {
                if map.shortcuts(for: command).contains(where: { map.refusal(for: $0, assigningTo: command) != nil }) {
                    map.overrides[command] = nil
                    dropped = true
                }
            }
        }
        self = map
    }
}
