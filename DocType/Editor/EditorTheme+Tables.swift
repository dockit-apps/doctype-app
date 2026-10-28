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

import AppKit
import DocTypeCore

/// What table layout needs from the editor.
struct TableContext {
    /// How wide a table may get: the text container's width, without padding.
    var width: CGFloat = 600
    /// The cell being edited: where it starts (after its opening pipe) and the
    /// height its editor needs.
    var editingCell: (location: Int, height: CGFloat)?
}

/// A table row as drawn, stored on the row's line. Positions are in the row's
/// layout fragment: x from where its text starts, y from its top.
nonisolated struct TableRowLayout: Hashable, @unchecked Sendable {
    struct Cell: Hashable, @unchecked Sendable {
        /// The cell between its pipes, relative to the start of the row's line.
        let range: NSRange
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
    /// Where the vertical grid lines go, left to right.
    let columnLines: [CGFloat]
    let height: CGFloat
    let cells: [Cell]

    /// The `|---|` row: hidden, it only continues the grid lines.
    var isDelimiter: Bool { index == 1 }
}

extension EditorTheme {
    /// Space between a cell's text and the grid lines beside it.
    static let tableCellPadding: CGFloat = 8
    /// Room above and below a cell's text.
    nonisolated static let tableRowPadding: CGFloat = 6
    /// Narrowest column, so an empty one is still easy to click; and narrowest a
    /// column gets when long text is wrapped to fit the editor.
    static let minimumColumnWidth: CGFloat = 24
    static let minimumWrappedColumnWidth: CGFloat = 64
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
        let columnCount = max((natural.keys.max() ?? 0) + 1, 1)
        let naturalWidths = (0..<columnCount).map { natural[$0] ?? minimumColumnWidth }
        let available = context.width - CGFloat(columnCount) * 2 * tableCellPadding - 1
        let widths = fitColumns(naturalWidths, into: available)
        var columnLines: [CGFloat] = [0]
        for width in widths { columnLines.append(columnLines[columnLines.count - 1] + width + 2 * tableCellPadding) }

        let isActive = context.editingCell.map { NSLocationInRange($0.location, tableRange) } == true
            || (selection.location <= NSMaxRange(tableRange) && NSMaxRange(selection) >= tableRange.location)
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
            var cells: [TableRowLayout.Cell] = []
            for (cell, cellText) in zip(row.cells, texts) {
                let column = min(cell.column, columnCount - 1)
                let frame = CGRect(x: columnLines[column] + tableCellPadding, y: tableRowPadding,
                                   width: widths[column], height: contentHeight)
                cells.append(TableRowLayout.Cell(
                    range: NSRange(location: cell.range.location - line.location, length: cell.range.length),
                    text: cellText, frame: frame, isEditing: context.editingCell?.location == cell.range.location))
            }
            let height = row.isDelimiter ? 1 : (contentHeight + 2 * tableRowPadding).rounded(.up)
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            style.paragraphSpacing = row.isLast ? tableButtonSpace : 0
            text.addAttributes([
                .paragraphStyle: style,
                tableRowKey: TableRowLayout(index: row.index, isLast: row.isLast, isActive: isActive,
                                            columnLines: columnLines, height: height, cells: cells),
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

    /// Column widths that fit `available`: columns narrower than an equal share
    /// keep their width, the others share the rest and wrap their text.
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
        return widths.enumerated().map { index, width in
            width < natural[index] ? max(width, minimumWrappedColumnWidth) : width
        }
    }
}
