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
        case .character(let character): result += character.uppercased()
        case .delete: result += "⌫"
        case .returnKey: result += "↩"
        }
        return result
    }
}
