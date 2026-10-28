// A keyboard shortcut described without AppKit/SwiftUI types, so core can define
// each command's default shortcut and tests can check them.

public struct Shortcut: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// Special keys that aren't a printable character.
    public enum Key: Hashable, Sendable {
        case character(Character)
        case delete      // ⌫
        case returnKey   // ↩
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Shorthand: `.command("n")`, `.command("p", .shift)`.
    public static func command(_ character: Character, _ extra: Modifiers = []) -> Shortcut {
        Shortcut(.character(Character(character.lowercased())), extra.union(.command))
    }

    /// The way macOS menus show it: modifiers in ⌃⌥⇧⌘ order, then the key (`⇧⌘P`).
    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        switch key {
        case .character(" "): result += "Space"
        case .character("\t"): result += "⇥"
        case .character(let character): result += character.uppercased()
        case .delete: result += "⌫"
        case .returnKey: result += "↩"
        }
        return result
    }

    /// For VoiceOver, which reads ⌘ and ⇧ badly: "Shift Command P".
    public var spokenString: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        switch key {
        case .character(" "): words.append("Space")
        case .character("\t"): words.append("Tab")
        case .character(let character): words.append(character.uppercased())
        case .delete: words.append("Delete")
        case .returnKey: words.append("Return")
        }
        return words.joined(separator: " ")
    }

    // MARK: - Storage

    private static let modifierNames: [(String, Modifiers)] =
        [("ctrl", .control), ("opt", .option), ("shift", .shift), ("cmd", .command)]

    /// A stable text form for settings, e.g. `shift+cmd+p`, `cmd+delete`.
    public var storageString: String {
        let names = Self.modifierNames.filter { modifiers.contains($0.1) }.map(\.0)
        let keyName = switch key {
        case .character(" "): "space"
        case .character("\t"): "tab"
        case .character(let character): String(character)
        case .delete: "delete"
        case .returnKey: "return"
        }
        return (names + [keyName]).joined(separator: "+")
    }

    /// Reads `storageString`; nil for anything else.
    public init?(storageString: String) {
        var rest = Substring(storageString)
        var modifiers: Modifiers = []
        var matched = true
        while matched {
            matched = false
            for (name, modifier) in Self.modifierNames where rest.hasPrefix(name + "+") && rest.count > name.count + 1 {
                rest = rest.dropFirst(name.count + 1)
                modifiers.insert(modifier)
                matched = true
            }
        }
        let key: Key
        switch rest {
        case "space": key = .character(" ")
        case "tab": key = .character("\t")
        case "delete": key = .delete
        case "return": key = .returnKey
        default:
            guard rest.count == 1, let character = rest.first else { return nil }
            key = .character(Character(character.lowercased()))
        }
        self.init(key, modifiers)
    }
}
