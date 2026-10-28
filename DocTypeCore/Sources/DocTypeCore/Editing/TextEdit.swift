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

    /// The edit that turns `old`, at `location` in a text, into `new` by
    /// replacing only the part that differs. The selection after it is the part
    /// that came in, or the cursor where text went out: where NSTextView's own
    /// undo leaves it, so undoing typing puts the cursor where it was typed and
    /// undoing a delete selects what came back.
    public static func replacing(_ old: String, with new: String, at location: Int) -> TextEdit {
        let (start, oldLength, replacement) = difference(old, new)
        let range = NSRange(location: location + start, length: oldLength)
        return TextEdit(range: range, replacement: replacement,
                        selectionAfter: NSRange(location: range.location, length: (replacement as NSString).length))
    }

    /// The same edit, replacing only the part of `range` that changes (`text`
    /// is the text before the edit); the selection after it stays. Undo then
    /// touches and selects only that part: undoing an added table row removes
    /// the row instead of rewriting, and selecting, the whole table.
    public func minimized(in text: NSString) -> TextEdit {
        let (start, oldLength, replacement) = Self.difference(text.substring(with: range), self.replacement)
        return TextEdit(range: NSRange(location: range.location + start, length: oldLength),
                        replacement: replacement, selectionAfter: selectionAfter)
    }

    /// Where `old` and `new` differ: the UTF-16 offset of the first different
    /// character, the UTF-16 length of `old`'s different part, and what `new`
    /// has instead. Characters are compared whole, by their UTF-16, so none is
    /// split and an "é" written as one or two scalars counts as different.
    private static func difference(_ old: String, _ new: String) -> (start: Int, oldLength: Int, replacement: String) {
        var oldStart = old.startIndex, newStart = new.startIndex
        while oldStart < old.endIndex, newStart < new.endIndex, old[oldStart].utf16.elementsEqual(new[newStart].utf16) {
            old.formIndex(after: &oldStart)
            new.formIndex(after: &newStart)
        }
        var oldEnd = old.endIndex, newEnd = new.endIndex
        while oldEnd > oldStart, newEnd > newStart {
            let oldLast = old.index(before: oldEnd), newLast = new.index(before: newEnd)
            guard old[oldLast].utf16.elementsEqual(new[newLast].utf16) else { break }
            oldEnd = oldLast
            newEnd = newLast
        }
        return (old.utf16.distance(from: old.startIndex, to: oldStart),
                old.utf16.distance(from: oldStart, to: oldEnd),
                String(new[newStart..<newEnd]))
    }
}
