// Table columns in the editor. A cell's text always starts the same distance
// from the grid, however many spaces the markdown has around it, and columns
// line up, all without changing the text:
// - spaces at a cell's edges are hidden (zero width);
// - each pipe is invisible and stretched, with the body font scaled only
//   horizontally, to hold all the space between two cells' text: padding on
//   both sides plus the space that lines the columns up. The grid line is
//   drawn at a stored offset inside it (the attribute's value).
// Line breaks in cells (`<br>`): a row is one line of text, and TextKit lays
// text out in order, so `b` in `| a<br>b | c |` can't sit under `a` while `c`
// sits beside it. So such cells hide their text, and their lines are drawn in
// the grid instead (BlockDecorations), always, also while editing them: the
// editor draws the cursor and selection there and maps clicks to the text
// itself (MarkdownTextView+TableCells), and the arrow keys move along the
// lines (TableEditing). Typing still goes into the text, so undo and saving
// work as everywhere. A row is as tall as its tallest cell.
// (Text lines placed out of order by hand aren't possible: TextKit 2 ignores
// hand-built line fragments for the cursor and clicks; tried.)
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
    static let tableCellLinesKey = NSAttributedString.Key("DocTypeTableCellLines")
    /// From one line of a cell to the next: a body line and the rows' line spacing.
    /// (The body font, 15 pt; read here without the main actor, since fragments may draw off it.)
    nonisolated static let tableLineAdvance: CGFloat = {
        let font = NSFont.systemFont(ofSize: 15)
        return (font.ascender - font.descender + font.leading).rounded(.up) + tableLineSpacing
    }()
    /// Hidden text of a cell drawn as lines: far smaller than other hidden
    /// syntax, as a long cell's tiny widths would add up to a visible sliver
    /// (where the system selection would show).
    static let drawnCellTextAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 0.001),
        .foregroundColor: NSColor.clear,
    ]
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
            if row != 1 {
                table.append(TableCellLayout(range: span.range, row: row, column: column, alignment: alignment))
            }
        }
        layOutColumns(table, in: text)
    }

    private struct TableCellLayout {
        let range: NSRange
        let row: Int
        let column: Int
        let alignment: TableAlignment
    }

    private static func layOutColumns(_ cells: [TableCellLayout], in text: NSMutableAttributedString) {
        guard !cells.isEmpty else { return }
        let string = text.mutableString

        // Each cell's text without the spaces around it, and its lines.
        let contents = cells.map { TableEditing.contentRange(of: $0.range, in: string) }
        let cellLines = cells.map { TableEditing.cellLines(of: $0.range, in: string) }
        var lineCounts: [Int: Int] = [:]
        for (cell, pieces) in zip(cells, cellLines) { lineCounts[cell.row] = max(lineCounts[cell.row] ?? 1, pieces.count) }
        // Cells with line breaks are drawn as lines.
        let drawn = cellLines.map { $0.count > 1 }

        var widths: [CGFloat] = []
        var cellDrawings: [(TableCellLayout, TableCellLines)] = []
        for (index, cell) in cells.enumerated() {
            let content = contents[index]
            if drawn[index] {
                let pieces = cellLines[index].map { $0.length == 0 ? NSAttributedString() : text.attributedSubstring(from: $0) }
                let pieceWidths = pieces.map { $0.size().width }
                widths.append(pieceWidths.max() ?? 0)
                let ranges = cellLines[index].map { NSRange(location: $0.location - cell.range.location, length: $0.length) }
                cellDrawings.append((cell, TableCellLines(lines: pieces, widths: pieceWidths, lineRanges: ranges,
                                                          columnWidth: 0, alignment: cell.alignment)))
                text.addAttributes(drawnCellTextAttributes, range: cell.range)
            } else {
                widths.append(content.length == 0 ? 0 : text.attributedSubstring(from: content).size().width)
                let before = NSRange(location: cell.range.location, length: content.location - cell.range.location)
                let after = NSRange(location: content.upperBound, length: cell.range.upperBound - content.upperBound)
                if before.length > 0 { text.addAttributes(concealedAttributes, range: before) }
                if after.length > 0 { text.addAttributes(concealedAttributes, range: after) }
            }
        }
        // What each cell takes up in the text line as styled: its text, or for a
        // drawn cell almost nothing (hidden text is tiny, not zero-width, and a
        // long cell adds up; measured only there, measuring is slow).
        let inLine = cells.indices.map { index in
            drawn[index] ? text.attributedSubstring(from: cells[index].range).size().width : widths[index]
        }
        var columnWidths: [Int: CGFloat] = [:]
        for (cell, width) in zip(cells, widths) {
            columnWidths[cell.column] = max(columnWidths[cell.column] ?? minimumColumnWidth, width)
        }

        // The space each pipe holds before its grid line (the cell on its left)
        // and after it (the cell on its right).
        var pipes: [Int: (before: CGFloat, after: CGFloat)] = [:]
        for (index, cell) in cells.enumerated() {
            // A drawn cell's text is hidden: its pipes hold the whole column, and
            // the lines are placed in it when drawn.
            let width = inLine[index]
            let extra = max((columnWidths[cell.column] ?? width) - width, 0)
            let (leading, trailing): (CGFloat, CGFloat) = switch cell.alignment {
            case _ where drawn[index]: (0, extra)  // aligned when drawn
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

        for (cell, drawing) in cellDrawings {
            let lines = TableCellLines(lines: drawing.lines, widths: drawing.widths, lineRanges: drawing.lineRanges,
                                       columnWidth: columnWidths[cell.column] ?? 0, alignment: drawing.alignment)
            text.addAttribute(tableCellLinesKey, value: lines, range: cell.range)
        }
        // Every row with line breaks is as tall as its tallest cell.
        var tallRows: Set<Int> = []
        for cell in cells where (lineCounts[cell.row] ?? 1) > 1 && tallRows.insert(cell.row).inserted {
            let extra = CGFloat((lineCounts[cell.row] ?? 1) - 1) * tableLineAdvance
            let paragraph = string.paragraphRange(for: cell.range)
            if let row = text.attribute(tableRowKey, at: paragraph.location, effectiveRange: nil) as? TableRowAttribute {
                var tall = row
                tall.extraHeight = extra
                text.addAttribute(tableRowKey, value: tall, range: paragraph)
            }
            let current = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let style = (current ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing += extra
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }
}

/// A table cell drawn as lines (it has `<br>`s), and where its text is: for
/// drawing it and for putting the cursor, selection and clicks on its lines.
/// Positions are relative to the cell: x from where its text starts, y from the
/// top of its first line; character offsets from the cell's start.
nonisolated struct TableCellLines: Hashable, @unchecked Sendable {
    let lines: [NSAttributedString]
    let widths: [CGFloat]
    /// Each line's text in the cell (offsets from the cell's start).
    let lineRanges: [NSRange]
    let columnWidth: CGFloat
    let alignment: TableAlignment

    /// How far line `index` is moved in by the column's alignment.
    func indent(ofLine index: Int) -> CGFloat {
        switch alignment {
        case .left: 0
        case .center: ((columnWidth - widths[index]) / 2).rounded()
        case .right: columnWidth - widths[index]
        }
    }

    /// The line a character offset is on (in a `<br>`: the line before it).
    func line(of offset: Int) -> Int {
        lineRanges.lastIndex { $0.location <= offset } ?? 0
    }

    /// Where the cursor at `offset` is drawn: x and the top of its line.
    func caretPoint(at offset: Int) -> CGPoint {
        let index = line(of: offset)
        let inLine = min(max(offset - lineRanges[index].location, 0), lineRanges[index].length)
        let ctLine = CTLineCreateWithAttributedString(lines[index])
        let x = CTLineGetOffsetForStringIndex(ctLine, inLine, nil)
        return CGPoint(x: indent(ofLine: index) + x, y: CGFloat(index) * EditorTheme.tableLineAdvance)
    }

    /// The character offset nearest to `point`.
    func offset(at point: CGPoint) -> Int {
        let index = min(max(Int(point.y / EditorTheme.tableLineAdvance), 0), lines.count - 1)
        let ctLine = CTLineCreateWithAttributedString(lines[index])
        let inLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: point.x - indent(ofLine: index), y: 0))
        return lineRanges[index].location + min(max(inLine, 0), lineRanges[index].length)
    }
}
