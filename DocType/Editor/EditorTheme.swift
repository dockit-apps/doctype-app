// How each markdown Style looks in the editor: fonts and colors. Colors are
// dynamic (light/dark) so switching appearance needs no restyling.

import AppKit
import DocTypeCore

enum EditorTheme {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Marks a line inside a code block and where it sits, for BlockDecorations.
    static let codeBlockLineKey = NSAttributedString.Key("DocTypeCodeBlockLine")
    /// Marks a line inside a block quote (drawn with a bar on the left).
    static let quoteLineKey = NSAttributedString.Key("DocTypeQuoteLine")
    /// Marks a `---` line (drawn as a horizontal rule).
    static let ruleLineKey = NSAttributedString.Key("DocTypeRuleLine")
    /// Marks a list bullet character (drawn as "•").
    static let bulletKey = NSAttributedString.Key("DocTypeBullet")
    /// Marks a task's "[ ]" (drawn as a checkbox); the value is true when checked.
    static let taskKey = NSAttributedString.Key("DocTypeTask")
    /// Marks a table row's line, for drawing the grid (value: TableRowAttribute).
    static let tableRowKey = NSAttributedString.Key("DocTypeTableRow")
    /// Marks a table's pipe characters, where the grid's vertical lines go. The
    /// value is the line's offset into the (stretched) pipe; see EditorTheme+Tables.
    static let tablePipeKey = NSAttributedString.Key("DocTypeTablePipe")
    /// Marks a link's text; the value is its destination (⌘-click opens it).
    static let linkKey = NSAttributedString.Key("DocTypeLink")
    /// Space between the quote bar and the quoted text.
    static let quoteIndent: CGFloat = 18

    /// Hidden markdown syntax: kept in the text, but takes no visible space.
    static let concealedAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 0.1),
        .foregroundColor: NSColor.clear,
    ]
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

    /// Resets `range` and applies `spans` (which must lie inside it). Markers the
    /// `selection` doesn't reveal are hidden; spans still unconfirmed at the cursor
    /// (`---` without a space yet) are left out. Returns image files that need
    /// measuring before they can be shown (see EditorTheme+Images).
    @discardableResult
    static func apply(_ spans: [StyleSpan], to text: NSMutableAttributedString, resetting range: NSRange,
                      selection: NSRange, images: ImageContext? = nil) -> [URL] {
        text.setAttributes(baseAttributes, range: range)
        var unmeasuredImages: [URL] = []
        for span in spans where !span.isHeldBack(by: selection) {
            switch span.style {
            case .tableRow(let index, let isLast):
                applyTableRow(span, index: index, isLast: isLast, to: text, selection: selection)
            case .image(let source, let width):
                if let url = applyImage(span, source: source, width: width, to: text, selection: selection, context: images) {
                    unmeasuredImages.append(url)
                }
            case .codeBlock:
                applyCodeBlock(span.range, to: text)
            case .blockquote:
                applyToLines(span.range, of: text) { _ in
                    [.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: quoteParagraphStyle, quoteLineKey: true]
                }
            case .horizontalRule:
                applyToLines(span.range, of: text) { _ in [.paragraphStyle: ruleParagraphStyle, ruleLineKey: true] }
            case .syntaxMarker where !span.isRevealed(by: selection), .hiddenMarker:
                text.addAttributes(concealedAttributes, range: span.range)
            case .strong:
                convertFonts(in: span.range, of: text) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            case .emphasis:
                convertFonts(in: span.range, of: text) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
            case .inlineCode:
                // Monospace at the surrounding size, so code in a heading stays heading-sized.
                convertFonts(in: span.range, of: text) { .monospacedSystemFont(ofSize: $0.pointSize * 0.92, weight: .regular) }
                text.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: span.range)
            default:
                text.addAttributes(attributes(for: span.style), range: span.range)
            }
        }
        alignTableColumns(spans, in: text, selection: selection)
        reserveImageSpace(in: range, of: text)
        return unmeasuredImages
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
        case .strikethrough:
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .link(let destination):
            [.foregroundColor: NSColor.linkColor, linkKey: destination]
        case .listBullet:
            // Keeps its width; BlockDecorations draws a bullet there.
            [.foregroundColor: NSColor.clear, bulletKey: true]
        case .lineBreak:
            [.foregroundColor: NSColor.tertiaryLabelColor]
        case .listNumber, .completedTask:
            [.foregroundColor: NSColor.secondaryLabelColor]
        case .taskBox(let checked):
            // Keeps its width; BlockDecorations draws a checkbox there.
            [.foregroundColor: NSColor.clear, taskKey: checked]
        case .tablePipe:
            // Stretched to space the columns, and the grid line drawn in it (EditorTheme+Tables).
            [.foregroundColor: NSColor.clear]
        case .horizontalRule, .hiddenMarker, .strong, .emphasis, .inlineCode, .tableCell, .tableRow, .image:
            [:]  // handled in apply(_:to:resetting:selection:)
        }
    }

    /// Replaces each font run in `range` with `transform(font)`, keeping sizes
    /// from headings and other styles applied before.
    private static func convertFonts(in range: NSRange, of text: NSMutableAttributedString,
                                     _ transform: (NSFont) -> NSFont) {
        var runs: [(NSRange, NSFont)] = []
        text.enumerateAttribute(.font, in: range) { value, runRange, _ in
            runs.append((runRange, value as? NSFont ?? bodyFont))
        }
        for (runRange, font) in runs {
            text.addAttribute(.font, value: transform(font), range: runRange)
        }
    }

    // MARK: - Tables

    /// Room above and below each row's text, inside the grid.
    nonisolated static let tableRowPadding: CGFloat = 5
    nonisolated static let tableLineSpacing: CGFloat = 3
    /// Extra room under a table's last row for its "add row" button.
    nonisolated static let tableButtonSpace: CGFloat = 20

    /// Marks a table row's line and pads it. The `|---|` row collapses to almost
    /// nothing (its line break is hidden too).
    private static func applyTableRow(_ span: StyleSpan, index: Int, isLast: Bool, to text: NSMutableAttributedString,
                                      selection: NSRange) {
        let paragraph = text.mutableString.paragraphRange(for: NSRange(location: span.range.location, length: 0))
        let isActive = span.isRevealed(by: selection)
        let style = NSMutableParagraphStyle()
        if index == 1 {  // the |---| row, always hidden
            text.addAttributes(concealedAttributes, range: paragraph)
            style.maximumLineHeight = 1
        } else {
            style.lineSpacing = tableLineSpacing
            style.paragraphSpacingBefore = tableRowPadding
            style.paragraphSpacing = tableRowPadding + (isLast ? tableButtonSpace : 0)
        }
        text.addAttributes([.paragraphStyle: style,
                            tableRowKey: TableRowAttribute(index: index, isLast: isLast, isActive: isActive)],
                           range: paragraph)
    }

    private static let quoteParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        // A new quote line holds only the hidden "> "; keep it full height.
        style.minimumLineHeight = 18
        style.firstLineHeadIndent = quoteIndent
        style.headIndent = quoteIndent
        return style
    }()

    /// Keeps a rule's line full height even when its `---` is hidden.
    private static let ruleParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 22
        return style
    }()

    /// Adds attributes to every whole line (paragraph) that `range` touches.
    private static func applyToLines(_ range: NSRange, of text: NSMutableAttributedString,
                                     _ attributes: (Int) -> [NSAttributedString.Key: Any]) {
        var lines: [NSRange] = []
        text.mutableString.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            lines.append(enclosing)
        }
        for (index, line) in lines.enumerated() {
            text.addAttributes(attributes(index), range: NSIntersectionRange(line, NSRange(location: 0, length: text.length)))
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

/// What's stored on a table row's line, for BlockDecorations.
nonisolated struct TableRowAttribute: Hashable, Sendable {
    let index: Int
    let isLast: Bool
    /// The cursor is in the table: its "add row" and "add column" buttons show.
    let isActive: Bool
    /// Room added under the row's text for cells drawn on several lines (`<br>`).
    var extraHeight: CGFloat = 0
}
