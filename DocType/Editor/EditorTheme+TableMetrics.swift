// Sizes in a drawn table: padding, the narrowest and most columns, how tall a
// cell's wrapped text is and where its characters are, and how columns share
// the width. Used by the layout in EditorTheme+Tables.

import AppKit
import DocTypeCore

extension EditorTheme {
    /// Space between a cell's text and the grid lines beside it.
    static let tableCellPadding: CGFloat = 8
    /// Room above and below a cell's text.
    nonisolated static let tableRowPadding: CGFloat = 6
    /// Narrowest column, so an empty one is still easy to click; and narrowest a
    /// column gets when long text is wrapped to fit the editor.
    static let minimumColumnWidth: CGFloat = 24
    static let minimumWrappedColumnWidth: CGFloat = 64
    /// Least cell padding: in a table a little too wide, or with more columns than fit.
    static let minimumCellPadding: CGFloat = 3
    /// Most columns a table gets here: as many as fit the full text column at
    /// `minimumWrappedColumnWidth` (eight).
    static let maximumTableColumns = Int(
        (MarkdownTextView.textColumnWidth - 1) / (minimumWrappedColumnWidth + 2 * tableCellPadding))
    /// A table's hidden markdown: far smaller than other hidden syntax, as a
    /// long row's tiny widths would add up.
    static let hiddenTableAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 0.001),
        .foregroundColor: NSColor.clear,
    ]

    /// A cell's text as it's drawn and edited: body text and line spacing,
    /// aligned like its column.
    static func cellParagraphStyle(_ alignment: TableAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = tableLineSpacing
        style.alignment = switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        return style
    }

    /// The height of a cell's text wrapped to `width`; an empty cell has one line's.
    static func cellTextHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let measured = text.length == 0 ? emptyCellHeight : text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return max(measured, emptyCellHeight).rounded(.up)
    }

    static let emptyCellHeight: CGFloat = NSAttributedString(
        string: " ", attributes: [.font: bodyFont, .paragraphStyle: cellParagraphStyle(.left)]
    ).boundingRect(with: CGSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height

    /// Where the characters in `range` of a cell's text are drawn when it's
    /// wrapped to `width`: a rectangle per line, from the cell text's top left.
    static func cellTextRects(_ text: NSAttributedString, width: CGFloat, range: NSRange) -> [CGRect] {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return [] }
        // TextKit 1 on its own, as NSAttributedString.draw lays the text out (not the editor's text view).
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [CGRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in
            rects.append(rect)
        }
        return rects
    }

    /// Column widths that fit `available`: columns narrower than an equal share
    /// keep their width, the others share the rest and wrap their text, at
    /// least `minimumWrappedColumnWidth` wide where that still fits.
    static func fitColumns(_ natural: [CGFloat], into available: CGFloat) -> [CGFloat] {
        guard natural.reduce(0, +) > available, !natural.isEmpty else { return natural }
        var widths = natural
        var remaining = available
        var open = Array(natural.indices)
        while !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            let narrow = open.filter { natural[$0] <= share }
            guard !narrow.isEmpty else {
                for index in open { widths[index] = share.rounded(.down) }
                break
            }
            for index in narrow { remaining -= natural[index] }
            open.removeAll { narrow.contains($0) }
        }
        let readable = widths.enumerated().map { index, width in
            width < natural[index] ? max(width, minimumWrappedColumnWidth) : width
        }
        return readable.reduce(0, +) <= available ? readable : widths.map { max($0, 1) }
    }
}
