// Table columns in the editor. A cell's text always starts the same distance
// from the grid, however many spaces the markdown has around it, and columns
// line up, all without changing the text:
// - spaces at a cell's edges are hidden (zero width);
// - each pipe is invisible and stretched, with the body font scaled only
//   horizontally, to hold all the space between two cells' text: padding on
//   both sides plus the space that lines the columns up. The grid line is
//   drawn at a stored offset inside it (the attribute's value).
// Alternatives tried: extra space (kerning) after a character, but TextKit 2
// puts the cursor halfway into that space while drawing the text after all of
// it, so the cursor floated away from the text; and glyph stretching
// (`.expansion`), which TextKit 2's layout ignores. A scaled font's glyph is
// simply wider, so the cursor sits exactly at its edges.

import AppKit
import DocTypeCore

extension EditorTheme {
    /// Space between a cell's text and the grid line, on each side.
    static let tableCellPadding: CGFloat = 8
    /// The narrowest column, so an empty one is still easy to click.
    static let minimumColumnWidth: CGFloat = 24
    private static let pipeWidth = ("|" as NSString).size(withAttributes: [.font: bodyFont]).width
    private static let stretchedPipeFonts = NSCache<NSNumber, NSFont>()

    /// The body font scaled horizontally so that "|" is `width` wide.
    static func pipeFont(width: CGFloat) -> NSFont {
        let rounded = max((width * 4).rounded() / 4, 1)
        let key = NSNumber(value: Double(rounded))
        if let font = stretchedPipeFonts.object(forKey: key) { return font }
        let transform = AffineTransform(scaleByX: rounded / pipeWidth, byY: 1)
        let font = NSFont(descriptor: bodyFont.fontDescriptor, textTransform: transform) ?? bodyFont
        stretchedPipeFonts.setObject(font, forKey: key)
        return font
    }

    /// Lays out every table's columns among `spans` (see the top of this file).
    /// A row wider than the editor still wraps.
    static func alignTableColumns(_ spans: [StyleSpan], in text: NSMutableAttributedString) {
        var table: [TableCellLayout] = []
        for span in spans {
            guard case .tableCell(let row, let column, let alignment) = span.style else { continue }
            if row == 0, column == 0 {
                layOutColumns(table, in: text)
                table.removeAll(keepingCapacity: true)
            }
            // The |---| row is hidden and takes no part.
            if row != 1 { table.append(TableCellLayout(range: span.range, column: column, alignment: alignment)) }
        }
        layOutColumns(table, in: text)
    }

    private struct TableCellLayout {
        let range: NSRange
        let column: Int
        let alignment: TableAlignment
    }

    private static func layOutColumns(_ cells: [TableCellLayout], in text: NSMutableAttributedString) {
        guard !cells.isEmpty else { return }
        let string = text.mutableString

        // Each cell's text without the spaces around it, which are hidden.
        let contents = cells.map { cell in
            let content = TableEditing.contentRange(of: cell.range, in: string)
            let before = NSRange(location: cell.range.location, length: content.location - cell.range.location)
            let after = NSRange(location: content.upperBound, length: cell.range.upperBound - content.upperBound)
            if before.length > 0 { text.addAttributes(concealedAttributes, range: before) }
            if after.length > 0 { text.addAttributes(concealedAttributes, range: after) }
            return content
        }
        let widths = contents.map { $0.length == 0 ? 0 : text.attributedSubstring(from: $0).size().width }
        var columnWidths: [Int: CGFloat] = [:]
        for (cell, width) in zip(cells, widths) {
            columnWidths[cell.column] = max(columnWidths[cell.column] ?? minimumColumnWidth, width)
        }

        // The space each pipe holds before its grid line (the cell on its left)
        // and after it (the cell on its right).
        var pipes: [Int: (before: CGFloat, after: CGFloat)] = [:]
        for (cell, width) in zip(cells, widths) {
            let extra = (columnWidths[cell.column] ?? width) - width
            let (leading, trailing): (CGFloat, CGFloat) = switch cell.alignment {
            case .left: (0, extra)
            case .right: (extra, 0)
            case .center: (extra / 2, extra / 2)
            }
            let opening = cell.range.location - 1
            if opening >= 0, string.character(at: opening) == 124 {  // "|"
                pipes[opening, default: (0, 0)].after = tableCellPadding + leading
            }
            let closing = cell.range.upperBound
            if closing < string.length, string.character(at: closing) == 124 {
                pipes[closing, default: (0, 0)].before = trailing + tableCellPadding
            }
        }
        for (location, space) in pipes {
            text.addAttributes([.font: pipeFont(width: space.before + space.after), tablePipeKey: space.before],
                               range: NSRange(location: location, length: 1))
        }
    }
}
