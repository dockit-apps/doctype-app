// What a piece of text should look like, in editor-neutral terms. The app maps
// each Style to fonts and colors (EditorTheme); core only decides which ranges
// get which style.

import Foundation

public enum Style: Hashable, Sendable {
    /// Heading text, sized by level 1–6.
    case heading(level: Int)
    /// Markdown syntax that stays visible but dimmed: `#`, `>`, fences, `**`, …
    case syntaxMarker
    /// The lines of a code block (monospace, drawn as a box).
    case codeBlock
    /// A syntax-highlighted token inside a fenced code block.
    case code(CodeToken)
    case blockquote
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

    public init(_ range: NSRange, _ style: Style) {
        self.range = range
        self.style = style
    }
}
