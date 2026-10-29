// Tables in the editor: drawn as a grid, each cell's text wrapped in its column
// with `<br>` shown as a line break, and every row as tall as its tallest cell.
//
// The table's markdown stays in the text, hidden (zero width). Each row's line
// gets the height of the drawn row, and the row's layout (TableRowLayout) is
// stored on the line, for BlockDecorations to draw and MarkdownTextView to
// hit-test. The cell being edited is shown by a real text view placed over it
// (TableCellSession): its text isn't drawn here, and its height is the editor's.
// Why not lay the cells out as text: TextKit lays a row out as one line, in
// order, so a cell's second line can't sit under its first while the next cell
// stays beside it, and a cell can't wrap within its column. (Tried: hidden text
// with stretched pipes, and line fragments placed by hand, which TextKit 2
// ignores for the cursor and clicks.)
//
// Width: a table never runs past the text column. Columns keep their natural
// width while they fit. A table a little too wide tightens its cell padding
// first (down to `minimumCellPadding`), so short words don't break; then the
// wide columns wrap, and a crowded one (many columns from elsewhere, or a
// narrow window) gives up padding before going wider. Adding columns stops at `maximumTableColumns`, as many as fit
// the full text column at a readable width (TableEditing refuses more), so a
// table made here never needs squeezing. Alternatives considered: scrolling
// a wide table sideways (Notion, GitHub), which would need its own scrolling,
// hit-testing and cell editor placement inside the note's text view; and
// letting tables use the window's full width, which breaks the text column
// and still has no limit.
//
// Selection: the note's selection is drawn in the cells it covers, since the
// markdown under them is hidden: whole cells when it reaches past one, or the
// selected text when it's inside one cell (a match Find selected).

import AppKit
import DocTypeCore

/// What table layout needs from the editor.
struct TableContext {
    /// How wide a table may get: the text container's width, without padding.
    var width: CGFloat = 600
    var editingCell: EditingCell?
    /// The note has the keyboard in the key window: its selection is drawn in
    /// the accent color, otherwise in gray (as NSTextView draws it).
    var isSelectionActive = true

    /// The cell being edited, as its editor shows it.
    struct EditingCell: Equatable {
        /// Where it starts (after its opening pipe).
        var location: Int
        /// The height its editor needs.
        var height: CGFloat
        /// How wide its text is unwrapped, with the markdown markers the editor
        /// shows on the cursor's line: its column is at least that wide, so
        /// showing them doesn't wrap the line.
        var width: CGFloat
    }
}

/// A table row as drawn, stored on the row's line. Positions are in the row's
/// layout fragment: x from where its text starts, y from its top.
nonisolated struct TableRowLayout: Hashable, @unchecked Sendable {
    struct Cell: Hashable, @unchecked Sendable {
        /// The cell between its pipes, relative to the start of the row's line.
        let range: NSRange
        /// Its text without the spaces around it (what `text` shows), relative
        /// to the start of the row's line.
        let content: NSRange
        let text: NSAttributedString
        /// Where its text is drawn, wrapped to this width.
        let frame: CGRect
        /// Shown by the cell editor instead.
        let isEditing: Bool
    }

    let index: Int
    let isLast: Bool
    /// The cursor is in the table: its "+" buttons show.
    let isActive: Bool
    /// The table has fewer than `maximumTableColumns`: "add column" shows.
    let canAddColumn: Bool
    /// Where the vertical grid lines go, left to right.
    let columnLines: [CGFloat]
    let height: CGFloat
    let cells: [Cell]
    /// The note's selection in this row: where it's drawn, and in which color.
    let selection: [CGRect]
    let isSelectionActive: Bool

    /// The `|---|` row: hidden, it only continues the grid lines.
    var isDelimiter: Bool { index == 1 }
}

extension EditorTheme {
    /// Lays out every table among `spans` (see the top of this file).
    static func layOutTables(_ spans: [StyleSpan], in text: NSMutableAttributedString, selection: NSRange,
                             context: TableContext?) {
        var rows: [TableRowSpan] = []
        var cells: [TableCellSpan] = []
        for span in spans {
            switch span.style {
            case .tableRow(let index, let isLast): rows.append(TableRowSpan(index: index, isLast: isLast, line: span.range))
            case .tableCell(let row, let column, let alignment):
                cells.append(TableCellSpan(row: row, column: column, alignment: alignment, range: span.range))
            default: break
            }
        }
        guard !rows.isEmpty else { return }
        rows.sort { $0.line.location < $1.line.location }
        cells.sort { $0.range.location < $1.range.location }
        // Split into tables (each starts with its header row), and give each row its cells.
        var table: [TableRowSpan] = []
        var cellIndex = 0
        for var row in rows {
            while cellIndex < cells.count, cells[cellIndex].range.location < row.line.location { cellIndex += 1 }
            while cellIndex < cells.count, NSMaxRange(cells[cellIndex].range) <= NSMaxRange(row.line) {
                row.cells.append(cells[cellIndex])
                cellIndex += 1
            }
            if row.index == 0, !table.isEmpty {
                layOutTable(table, in: text, selection: selection, context: context ?? TableContext())
                table.removeAll()
            }
            table.append(row)
        }
        layOutTable(table, in: text, selection: selection, context: context ?? TableContext())
    }

    private struct TableRowSpan {
        let index: Int
        let isLast: Bool
        let line: NSRange
        var cells: [TableCellSpan] = []
        var isDelimiter: Bool { index == 1 }
    }

    private struct TableCellSpan {
        let row: Int
        let column: Int
        let alignment: TableAlignment
        let range: NSRange
    }

    private static func layOutTable(_ rows: [TableRowSpan], in text: NSMutableAttributedString, selection: NSRange,
                                    context: TableContext) {
        guard let first = rows.first, let last = rows.last else { return }
        let string = text.mutableString
        let tableRange = NSRange(location: first.line.location, length: NSMaxRange(last.line) - first.line.location)

        // Each cell's text as it reads, and how wide it is unwrapped.
        var shown: [[NSAttributedString]] = []
        var natural: [Int: CGFloat] = [:]
        for row in rows {
            let texts = row.isDelimiter ? [] : row.cells.map { cell in
                displayText(of: TableEditing.contentRange(of: cell.range, in: string), alignment: cell.alignment, in: text)
            }
            for (cell, shownText) in zip(row.cells, texts) {
                let width = shownText.length == 0 ? 0 : shownText.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).width.rounded(.up)
                natural[cell.column] = max(natural[cell.column] ?? minimumColumnWidth, width)
            }
            shown.append(texts)
        }
        let edited = context.editingCell.flatMap { editing in
            rows.lazy.flatMap(\.cells).first { $0.range.location == editing.location }.map { (editing, $0.column) }
        }
        if let (cell, column) = edited { natural[column] = max(natural[column] ?? minimumColumnWidth, cell.width) }
        let columnCount = max((natural.keys.max() ?? 0) + 1, 1)
        let naturalWidths = (0..<columnCount).map { natural[$0] ?? minimumColumnWidth }
        let room = context.width - 1
        // The padding that fits every column unwrapped, if it isn't too tight;
        // else what a column of `minimumColumnWidth` leaves.
        let unwrapped = ((room - naturalWidths.reduce(0, +)) / CGFloat(2 * columnCount)).rounded(.down)
        let crowded = ((room / CGFloat(columnCount) - minimumColumnWidth) / 2).rounded(.down)
        let padding = min(tableCellPadding, max(minimumCellPadding, unwrapped >= minimumCellPadding ? unwrapped : crowded))
        let widths = fitColumns(naturalWidths, into: room - CGFloat(columnCount) * 2 * padding)
        var columnLines: [CGFloat] = [0]
        for width in widths { columnLines.append(columnLines[columnLines.count - 1] + width + 2 * padding) }

        let isActive = edited != nil
            || (selection.location <= NSMaxRange(tableRange) && NSMaxRange(selection) >= tableRange.location)
        // A selection inside one cell's text shows as text; one reaching further, as whole cells.
        let selectedCell = selection.length == 0 ? nil : rows.lazy.flatMap(\.cells).first {
            selection.location >= $0.range.location && NSMaxRange(selection) <= NSMaxRange($0.range)
        }
        for (row, texts) in zip(rows, shown) {
            let line = string.paragraphRange(for: NSRange(location: row.line.location, length: 0))
            text.addAttributes(hiddenTableAttributes, range: line)
            var heights: [CGFloat] = []
            for (cell, cellText) in zip(row.cells, texts) {
                let width = widths[min(cell.column, columnCount - 1)]
                let editing = context.editingCell.flatMap { $0.location == cell.range.location ? $0.height : nil }
                heights.append(editing ?? cellTextHeight(cellText, width: width))
            }
            let contentHeight = max(heights.max() ?? 0, emptyCellHeight)
            let height = row.isDelimiter ? 1 : (contentHeight + 2 * tableRowPadding).rounded(.up)
            var cells: [TableRowLayout.Cell] = []
            var selected: [CGRect] = []
            for (cell, cellText) in zip(row.cells, texts) {
                let column = min(cell.column, columnCount - 1)
                let frame = CGRect(x: columnLines[column] + padding, y: tableRowPadding,
                                   width: widths[column], height: contentHeight)
                let content = TableEditing.contentRange(of: cell.range, in: string)
                let isEditing = context.editingCell?.location == cell.range.location
                cells.append(TableRowLayout.Cell(
                    range: NSRange(location: cell.range.location - line.location, length: cell.range.length),
                    content: NSRange(location: content.location - line.location, length: content.length),
                    text: cellText, frame: frame, isEditing: isEditing))
                if isEditing || selection.length == 0 { continue }  // the cell editor shows its own
                if let selectedCell {
                    guard selectedCell.range == cell.range else { continue }
                    let inCell = NSIntersectionRange(selection, content)
                    let shownRange = TableCellText(markdown: string.substring(with: content)).editorRange(
                        forMarkdownRange: NSRange(location: inCell.location - content.location, length: inCell.length))
                    selected += cellTextRects(cellText, width: frame.width, range: shownRange)
                        .map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
                } else if NSIntersectionRange(selection, cell.range).length > 0 {
                    selected.append(CGRect(x: columnLines[column], y: 0,
                                           width: columnLines[column + 1] - columnLines[column], height: height))
                }
            }
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            style.paragraphSpacing = row.isLast ? tableButtonSpace : 0
            text.addAttributes([
                .paragraphStyle: style,
                tableRowKey: TableRowLayout(index: row.index, isLast: row.isLast, isActive: isActive,
                                            canAddColumn: columnCount < maximumTableColumns,
                                            columnLines: columnLines, height: height, cells: cells, selection: selected,
                                            isSelectionActive: context.isSelectionActive),
            ], range: line)
        }
    }

    /// A cell's markdown as it reads: styled as in the note, `<br>` as a line
    /// break and `\|` as "|", in the cell's paragraph style.
    private static func displayText(of content: NSRange, alignment: TableAlignment,
                                    in text: NSMutableAttributedString) -> NSAttributedString {
        guard content.length > 0 else { return NSAttributedString() }
        let shown = NSMutableAttributedString(attributedString: text.attributedSubstring(from: content))
        let local = shown.mutableString
        for lineBreak in TableEditing.lineBreaks(in: NSRange(location: 0, length: local.length), of: local).reversed() {
            shown.replaceCharacters(in: lineBreak, with: "\n")
        }
        var search = NSRange(location: 0, length: local.length)
        while search.length > 0, case let escape = local.range(of: "\\|", options: [], range: search),
              escape.location != NSNotFound {
            shown.replaceCharacters(in: NSRange(location: escape.location, length: 1), with: "")
            search = NSRange(location: escape.location + 1, length: local.length - escape.location - 1)
        }
        shown.addAttribute(.paragraphStyle, value: cellParagraphStyle(alignment), range: NSRange(location: 0, length: shown.length))
        return shown
    }
}
