// What a piece of text should look like, in editor-neutral terms. The app maps
// each Style to fonts and colors (EditorTheme); core only decides which ranges
// get which style.

import Foundation

public enum Style: Hashable, Sendable {
    /// Heading text, sized by level 1–6.
    case heading(level: Int)
    /// Markdown syntax (`#`, `>`, fences, `**`, …). Shown dimmed while the cursor
    /// is inside the span's `revealRange`, hidden otherwise (like Obsidian).
    case syntaxMarker
    /// Syntax that's always hidden because a drawing replaces it: the quote bar
    /// replaces "> ", so its text lines up with the line above.
    case hiddenMarker
    /// The lines of a code block (monospace, drawn as a box).
    case codeBlock
    /// A syntax-highlighted token inside a fenced code block.
    case code(CodeToken)
    case blockquote
    /// A `---` line, drawn as a horizontal rule.
    case horizontalRule

    // Inline
    case strong
    case emphasis
    case strikethrough
    case inlineCode
    /// A link's visible text (its URL syntax is a marker). `destination` is what
    /// ⌘-click opens: a URL, or a path relative to the note.
    case link(destination: String)

    // Lists
    /// "-", "*" or "+" of a list item: keeps its width but is drawn as a bullet.
    case listBullet
    /// "1." or "1)" of an ordered list item: stays visible, dimmed.
    case listNumber
    /// "[ ]" or "[x]" of a task: keeps its width but is drawn as a checkbox.
    case taskBox(checked: Bool)
    /// The text of a completed task.
    case completedTask
}

/// Kinds of code tokens the editor colors.
public enum CodeToken: Hashable, Sendable {
    case keyword
    case string
    case comment
    case number
    case type
}

public struct StyleSpan: Equatable, Sendable {
    /// UTF-16 range in the document.
    public let range: NSRange
    public let style: Style
    /// For markers: where the cursor must be for the marker to show (its line, or
    /// the whole code block for fences). Nil means always shown.
    public let revealRange: NSRange?
    /// For constructs that aren't "confirmed" yet: while the cursor is in this range
    /// the span isn't applied at all, so `---` stays plain dashes until you type a
    /// space after it or leave the line. Nil means always applied.
    public let unconfirmedRange: NSRange?

    public init(_ range: NSRange, _ style: Style, revealRange: NSRange? = nil, unconfirmedRange: NSRange? = nil) {
        self.range = range
        self.style = style
        self.revealRange = revealRange
        self.unconfirmedRange = unconfirmedRange
    }

    /// True if a cursor or selection at `selection` should show this marker.
    /// Touching counts: a cursor at the end of the line reveals the line's markers.
    public func isRevealed(by selection: NSRange) -> Bool {
        guard let reveal = revealRange else { return true }
        return Self.touches(selection, reveal)
    }

    /// True if the span should be left out because the cursor is still on its
    /// unconfirmed syntax.
    public func isHeldBack(by selection: NSRange) -> Bool {
        guard let unconfirmed = unconfirmedRange else { return false }
        return Self.touches(selection, unconfirmed)
    }

    private static func touches(_ selection: NSRange, _ range: NSRange) -> Bool {
        selection.location <= range.upperBound && selection.upperBound >= range.location
    }
}
