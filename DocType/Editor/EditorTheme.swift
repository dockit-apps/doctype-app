// How each markdown Style looks in the editor: fonts and colors. Colors are
// dynamic (light/dark) so switching appearance needs no restyling.

import AppKit
import DocTypeCore

enum EditorTheme {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Marks a line inside a code block and where it sits, for CodeBlockLayout.
    static let codeBlockLineKey = NSAttributedString.Key("DocTypeCodeBlockLine")
    /// Inner padding of the code block box.
    static let codeBlockPadding: CGFloat = 12

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return style
    }()

    /// Every character starts from these; styles are added on top.
    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: NSColor.textColor,
        .paragraphStyle: paragraphStyle,
    ]

    /// Resets `range` and applies `spans` (which must lie inside it).
    static func apply(_ spans: [StyleSpan], to text: NSMutableAttributedString, resetting range: NSRange) {
        text.setAttributes(baseAttributes, range: range)
        for span in spans {
            if span.style == .codeBlock {
                applyCodeBlock(span.range, to: text)
            } else {
                text.addAttributes(attributes(for: span.style), range: span.range)
            }
        }
    }

    static func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading(let level):
            [.font: headingFont(level: level)]
        case .syntaxMarker:
            [.foregroundColor: NSColor.tertiaryLabelColor]
        case .codeBlock:
            [.font: codeFont]
        case .code(let token):
            [.foregroundColor: color(for: token)]
        case .blockquote:
            [.foregroundColor: NSColor.secondaryLabelColor]
        }
    }

    /// Monospace, inner padding, and a line-position marker on each line, so the
    /// layout can draw one rounded box around the block.
    private static func applyCodeBlock(_ range: NSRange, to text: NSMutableAttributedString) {
        let string = text.mutableString
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            lines.append(NSIntersectionRange(enclosing, range).length > 0 ? NSIntersectionRange(enclosing, range) : enclosing)
        }
        for (index, line) in lines.enumerated() {
            let position: CodeBlockLinePosition = lines.count == 1 ? .only
                : index == 0 ? .first : index == lines.count - 1 ? .last : .middle
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.firstLineHeadIndent = codeBlockPadding
            style.headIndent = codeBlockPadding
            style.tailIndent = -codeBlockPadding
            if position == .first || position == .only { style.paragraphSpacingBefore = codeBlockPadding * 0.6 }
            if position == .last || position == .only { style.paragraphSpacing = codeBlockPadding * 0.6 }
            text.addAttributes([.font: codeFont, .paragraphStyle: style, codeBlockLineKey: position.rawValue], range: line)
        }
    }

    private static func headingFont(level: Int) -> NSFont {
        let sizes: [CGFloat] = [26, 21, 18, 16, 15, 15]
        let size = sizes[min(max(level, 1), 6) - 1]
        return NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
    }

    // MARK: - Code colors (close to Xcode's defaults)

    private static func color(for token: CodeToken) -> NSColor {
        switch token {
        case .keyword: dynamic(light: 0xAD3DA4, dark: 0xFC5FA3)
        case .string: dynamic(light: 0xC41A16, dark: 0xFC6A5D)
        case .comment: dynamic(light: 0x6C7986, dark: 0x7F8C98)
        case .number: dynamic(light: 0x1C00CF, dark: 0xD0BF69)
        case .type: dynamic(light: 0x3E6D74, dark: 0x5DD8FF)
        }
    }

    nonisolated static func dynamic(light: Int, dark: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
    }
}

/// Where a line sits in its code block; decides which corners of the box are rounded.
nonisolated enum CodeBlockLinePosition: Int {
    case first, middle, last, only
}
