// How each markdown Style looks in the editor: fonts and colors. Colors are
// dynamic system colors, so light and dark mode work without restyling.

import AppKit
import DocTypeCore

enum EditorTheme {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

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

    static func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading(let level):
            [.font: headingFont(level: level)]
        case .syntaxMarker:
            [.foregroundColor: NSColor.tertiaryLabelColor]
        case .codeBlock:
            [.font: codeFont, .backgroundColor: NSColor.quaternarySystemFill]
        case .blockquote:
            [.foregroundColor: NSColor.secondaryLabelColor]
        }
    }

    private static func headingFont(level: Int) -> NSFont {
        let sizes: [CGFloat] = [26, 21, 18, 16, 15, 15]
        let size = sizes[min(max(level, 1), 6) - 1]
        return NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
    }
}
