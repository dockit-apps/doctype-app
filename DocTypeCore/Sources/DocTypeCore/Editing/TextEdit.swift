// One change to the editor's text: replace a range, then put the cursor somewhere.
// Editing behaviors in core return TextEdits; the app applies them as one undo step.

import Foundation

public struct TextEdit: Equatable, Sendable {
    /// UTF-16 range to replace, in the text before the edit.
    public let range: NSRange
    public let replacement: String
    /// The selection after the edit, in the text after it.
    public let selectionAfter: NSRange

    public init(range: NSRange, replacement: String, selectionAfter: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selectionAfter = selectionAfter
    }

    /// True for an edit that changes no text, only (maybe) the selection: a key
    /// that should do nothing, or one that moves the cursor.
    public var isNoChange: Bool { range.length == 0 && replacement.isEmpty }

    /// Applies the edit to a copy of `text` (for tests and headless use).
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}
