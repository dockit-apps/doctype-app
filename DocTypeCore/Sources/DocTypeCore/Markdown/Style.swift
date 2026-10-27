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
    /// The lines of a code block (monospace, drawn as a box).
    case codeBlock
    /// A syntax-highlighted token inside a fenced code block.
    case code(CodeToken)
    case blockquote
    /// A `---` line, drawn as a horizontal rule.
    case horizontalRule
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

    public init(_ range: NSRange, _ style: Style, revealRange: NSRange? = nil) {
        self.range = range
        self.style = style
        self.revealRange = revealRange
    }

    /// True if a cursor or selection at `selection` should show this marker.
    /// Touching counts: a cursor at the end of the line reveals the line's markers.
    public func isRevealed(by selection: NSRange) -> Bool {
        guard let reveal = revealRange else { return true }
        return selection.location <= reveal.upperBound && selection.upperBound >= reveal.location
    }
}
