// Editing GFM tables as tables: inserting one, adding and deleting rows and
// columns, aligning a column, and where the keys move between cells.
//
// The editor draws a table as a grid and edits one cell at a time in a cell
// editor (see the app's TableCellSession); this file is the markdown side.
// Behavior, and why (spreadsheet and Typora conventions):
// - Tab goes to the next cell, Shift-Tab to the previous one; Tab in the last
//   cell adds a row. Arrow keys at a cell's edge go to the neighboring cell,
//   and past the table's first or last cell out of the table.
// - Return moves to the same column in the next row, adding a row at the end;
//   Return on an empty last row removes it and leaves the table, like an empty
//   list item ends a list.
// - Structural edits (columns, alignment) rewrite each row as `| a | b |`,
//   keeping every cell's text, spacing and the row's indentation; adding or
//   deleting a row only touches that row. The header row can't be deleted
//   (GFM needs it), and neither can a table's last column.
// Alternatives considered: re-formatting the whole table to padded columns on
// every edit (makes diffs noisy, and the editor draws the columns anyway), and
// Return inserting a new row always (then there's no quick way out of a table).
import Foundation

public enum TableOperation: Hashable, Sendable {
    case addRowAbove, addRowBelow, addColumnLeft, addColumnRight, deleteRow, deleteColumn
    case align(TableAlignment)
}

/// A table found in the text: each row's line and cells. Row 1 is the `|---|` row.
public struct TableLayout: Equatable, Sendable {
    /// Each row's line, without its line break.
    public let lines: [NSRange]
    public let cells: [[NSRange]]
    /// Leading spaces of each line, kept when rows are rewritten.
    let indents: [String]

    public var range: NSRange { NSRange(location: lines[0].location, length: lines.last!.upperBound - lines[0].location) }
    public var columnCount: Int { cells[0].count }

    /// The row and column at `location`; a location on a pipe belongs to the cell after it.
    public func position(of location: Int) -> (row: Int, column: Int)? {
        guard let row = lines.firstIndex(where: { location >= $0.location && location <= $0.upperBound }) else { return nil }
        let rowCells = cells[row]
        guard !rowCells.isEmpty else { return (row, 0) }
        let column = rowCells.firstIndex { location <= $0.upperBound } ?? rowCells.count - 1
        return (row, column)
    }
}

public enum TableEditing {
    private static let delimiterRow = try! NSRegularExpression(
        pattern: #"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)

    // MARK: - Finding a table

    /// The table whose rows include `location`: the run of non-blank lines with
    /// pipes around it, whose second line is a `|---|` row. Nil outside tables
    /// and inside code blocks.
    public static func table(at location: Int, in text: NSString, blockMap: BlockMap) -> TableLayout? {
        guard location >= 0, location <= text.length else { return nil }
        if case .code = blockMap.blocks(in: NSRange(location: location, length: 0)).first?.kind { return nil }
        guard isRowLine(lineContaining(location, in: text), in: text) else { return nil }

        var lines = [lineContaining(location, in: text)]
        while lines[0].location > 0 {
            let previous = lineContaining(lines[0].location - 1, in: text)
            guard isRowLine(previous, in: text) else { break }
            lines.insert(previous, at: 0)
        }
        while true {
            var lineEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: lines.last!)
            guard lineEnd < text.length, lineEnd > lines.last!.upperBound else { break }
            let next = lineContaining(lineEnd, in: text)
            guard isRowLine(next, in: text) else { break }
            lines.append(next)
        }
        // The delimiter row must be second; rows above an earlier table's text don't belong.
        guard let delimiter = lines.firstIndex(where: { isDelimiterRow($0, in: text) }), delimiter >= 1 else { return nil }
        lines = Array(lines[(delimiter - 1)...])
        guard lines.contains(where: { NSLocationInRange(location, $0) || location == $0.upperBound }) else { return nil }
        let cells = lines.map { TableRowParsing.cells(in: $0, of: text).cells }
        guard !cells[0].isEmpty else { return nil }
        let indents = lines.map { line in
            String(text.substring(with: line).prefix { $0 == " " || $0 == "\t" })
        }
        return TableLayout(lines: lines, cells: cells, indents: indents)
    }

    /// How column `column` is aligned, from the `|---|` row (`:--`, `:-:`, `--:`).
    public static func alignment(ofColumn column: Int, in table: TableLayout, text: NSString) -> TableAlignment {
        guard table.cells.count > 1, column < table.cells[1].count else { return .left }
        let marker = text.substring(with: table.cells[1][column]).trimmingCharacters(in: .whitespaces)
        switch (marker.hasPrefix(":"), marker.hasSuffix(":")) {
        case (true, true): return .center
        case (false, true): return .right
        default: return .left
        }
    }

    private static func lineContaining(_ location: Int, in text: NSString) -> NSRange {
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    private static func isRowLine(_ line: NSRange, in text: NSString) -> Bool {
        line.length > 0 && !TableRowParsing.cells(in: line, of: text).pipes.isEmpty
    }

    static func isDelimiterRow(_ line: NSRange, in text: NSString) -> Bool {
        delimiterRow.firstMatch(in: text as String, range: line) != nil
    }

    // MARK: - Inserting a table

    /// A 2-column table with a header and one empty row, on lines of its own at
    /// the cursor, with "Column 1" selected so typing names it.
    public static func insertTable(in text: NSString, selection: NSRange) -> TextEdit {
        let location = selection.location
        let line = lineContaining(location, in: text)
        let body = "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |"
        // A blank line before and after keeps it apart from the text around it:
        // right under a list item or a quote, it would be part of that instead.
        func isBlank(_ line: NSRange) -> Bool {
            text.substring(with: line).allSatisfy { $0 == " " || $0 == "\t" }
        }
        let before = if location > line.location { "\n\n" }
            else if line.location > 0, !isBlank(lineContaining(line.location - 1, in: text)) { "\n" }
            else { "" }
        var nextLine = 0
        text.getLineStart(nil, end: &nextLine, contentsEnd: nil, for: line)
        let after = if location < line.upperBound { "\n\n" }
            else if nextLine < text.length, !isBlank(lineContaining(nextLine, in: text)) { "\n" }
            else { "" }
        let start = location + (before as NSString).length
        return TextEdit(range: NSRange(location: location, length: 0), replacement: before + body + after,
                        selectionAfter: NSRange(location: start + 2, length: 8))
    }

    // MARK: - Rows and columns

    /// Applies `operation` to the table at `location`. Nil outside a table or
    /// when the operation isn't possible (deleting the header row or the last column).
    public static func edit(_ operation: TableOperation, at location: Int, in text: NSString, blockMap: BlockMap) -> TextEdit? {
        guard let table = table(at: location, in: text, blockMap: blockMap),
              let (row, column) = table.position(of: location) else { return nil }
        var rows = table.cells.enumerated().map { index, cells in
            var texts = cells.map { text.substring(with: $0) }
            // Without a leading pipe, the row's indentation is part of its first cell.
            if let first = cells.first, first.location == table.lines[index].location {
                texts[0] = String(texts[0].dropFirst(table.indents[index].count))
            }
            return texts + Array(repeating: "  ", count: max(0, table.columnCount - cells.count))
        }
        let isDelimiter = { (index: Int) in index == 1 }
        var target = (row: row, column: column)

        switch operation {
        case .addRowAbove, .addRowBelow:
            // Above the header or below it (on the delimiter) both mean "the first body row".
            let index = operation == .addRowAbove ? max(row, 2) : max(row + 1, 2)
            rows.insert(Array(repeating: "  ", count: table.columnCount), at: index)
            target.row = index
        case .addColumnLeft, .addColumnRight:
            let index = operation == .addColumnLeft ? column : column + 1
            for i in rows.indices { rows[i].insert(isDelimiter(i) ? " --- " : "  ", at: min(index, rows[i].count)) }
            target.column = index
        case .deleteRow:
            guard row >= 2 else { return nil }
            rows.remove(at: row)
            target.row = min(row, rows.count - 1)
        case .deleteColumn:
            guard table.columnCount > 1 else { return nil }
            for i in rows.indices where column < rows[i].count { rows[i].remove(at: column) }
            target.column = min(column, table.columnCount - 2)
        case .align(let alignment):
            let dashes: String = switch alignment {
            case .left: ":---"
            case .center: ":---:"
            case .right: "---:"
            }
            guard column < rows[1].count else { return nil }
            rows[1][column] = " \(dashes) "
        }

        let lines = rows.enumerated().map { index, cells in
            let indent = index < table.indents.count ? table.indents[index] : table.indents[0]
            return indent + "|" + cells.joined(separator: "|") + "|"
        }
        let replacement = lines.joined(separator: "\n")
        // Put the cursor inside the target cell (after its first space).
        let lineStart = lines[..<target.row].reduce(table.range.location) { $0 + ($1 as NSString).length + 1 }
        let line = lines[target.row] as NSString
        let cellsBefore = rows[target.row][..<min(target.column, rows[target.row].count)]
        let offset = (table.indents[min(target.row, table.indents.count - 1)] as NSString).length + 1
            + cellsBefore.reduce(0) { $0 + ($1 as NSString).length + 1 }
        let cursor = lineStart + min(offset + 1, line.length)
        return TextEdit(range: table.range, replacement: replacement, selectionAfter: NSRange(location: cursor, length: 0))
            .minimized(in: text)
    }

    // MARK: - Moving between cells

    /// A key that moves out of a cell (at its edge, for the arrows).
    public enum CellKey: Sendable {
        case left, right, up, down, tab, backtab, newline
    }

    /// Where a key goes from the cell at `row`, `column`.
    public enum CellTarget: Equatable, Sendable {
        case cell(row: Int, column: Int)
        /// Out of the table, to the text above or below it.
        case leaveAbove, leaveBelow
        /// Add a row under the last one and go to its cell in `column`.
        case addRow(column: Int)
        /// Remove the (empty) last row and leave the table below.
        case removeLastRowAndLeave
    }

    /// Where `key` goes from the cell at `row`, `column` of `table`. Rows are
    /// visited in order without the `|---|` row; a row with fewer cells than
    /// the header has its last cell used instead of missing ones.
    public static func target(of key: CellKey, fromRow row: Int, column: Int, in table: TableLayout,
                              text: NSString) -> CellTarget {
        let rows = table.cells.indices.filter { $0 != 1 }
        guard let index = rows.firstIndex(of: row) else { return .cell(row: row, column: column) }
        let previous = index > 0 ? rows[index - 1] : nil
        let next = index + 1 < rows.count ? rows[index + 1] : nil
        let lastColumn = { (row: Int) in max(table.cells[row].count - 1, 0) }
        switch key {
        case .left, .backtab:
            if column > 0 { return .cell(row: row, column: column - 1) }
            if let previous { return .cell(row: previous, column: lastColumn(previous)) }
            return key == .left ? .leaveAbove : .cell(row: row, column: column)
        case .right, .tab:
            if column < lastColumn(row) { return .cell(row: row, column: column + 1) }
            if let next { return .cell(row: next, column: 0) }
            return key == .right ? .leaveBelow : .addRow(column: 0)
        case .up:
            guard let previous else { return .leaveAbove }
            return .cell(row: previous, column: min(column, lastColumn(previous)))
        case .down:
            guard let next else { return .leaveBelow }
            return .cell(row: next, column: min(column, lastColumn(next)))
        case .newline:
            if let next { return .cell(row: next, column: min(column, lastColumn(next))) }
            let isEmpty = table.cells[row].allSatisfy { contentRange(of: $0, in: text).length == 0 }
            return row >= 2 && isEmpty ? .removeLastRowAndLeave : .addRow(column: column)
        }
    }

    /// Empties the table's last row: its line stays, now an empty line after the
    /// table (an empty line ends a table), and the cursor goes there.
    public static func editRemovingLastRow(of table: TableLayout, in text: NSString) -> TextEdit {
        let last = table.lines[table.lines.count - 1]
        return TextEdit(range: last, replacement: "", selectionAfter: NSRange(location: last.location, length: 0))
    }

    /// Each `<br>` in `range`. Scanned on the NSString itself (no copy): this runs
    /// for every cell on every keystroke in a table.
    public static func lineBreaks(in range: NSRange, of text: NSString) -> [NSRange] {
        var found: [NSRange] = []
        var search = range
        while search.length > 0 {
            let open = text.range(of: "<br", options: .caseInsensitive, range: search)
            guard open.location != NSNotFound else { break }
            var end = open.upperBound
            while end < range.upperBound, [32, 9].contains(text.character(at: end)) { end += 1 }  // spaces, tabs
            if end < range.upperBound, text.character(at: end) == 47 { end += 1 }  // "/"
            if end < range.upperBound, text.character(at: end) == 62 {  // ">"
                found.append(NSRange(location: open.location, length: end + 1 - open.location))
                end += 1
            }
            let next = max(end, open.upperBound)
            search = NSRange(location: next, length: range.upperBound - next)
        }
        return found
    }


    /// A cell's text without its padding; for an empty cell, a cursor after its first space.
    public static func contentRange(of cell: NSRange, in text: NSString) -> NSRange {
        let content = text.substring(with: cell) as NSString
        let leading = content.rangeOfCharacter(from: CharacterSet(charactersIn: " \t").inverted)
        guard leading.location != NSNotFound else {
            return NSRange(location: cell.location + min(1, cell.length), length: 0)
        }
        let trailing = content.rangeOfCharacter(from: CharacterSet(charactersIn: " \t").inverted, options: .backwards)
        return NSRange(location: cell.location + leading.location, length: trailing.upperBound - leading.location)
    }
}

/// Splitting a table row into cells, shared by styling and editing.
enum TableRowParsing {
    /// The text of each cell and where the pipes are (`\|` is not a pipe). Text
    /// before the first pipe or after the last one is a cell only if it isn't
    /// blank (`a | b` has two cells, `| a | b |` too).
    static func cells(in line: NSRange, of source: NSString) -> (cells: [NSRange], pipes: [Int]) {
        var pipes: [Int] = []
        var backslashes = 0
        for location in line.location..<line.upperBound {
            let character = source.character(at: location)
            if character == 124, backslashes % 2 == 0 { pipes.append(location) }  // "|"
            backslashes = character == 92 ? backslashes + 1 : 0  // "\"
        }
        let bounds = [line.location - 1] + pipes + [line.upperBound]
        func isBlank(_ range: NSRange) -> Bool {
            source.substring(with: range).allSatisfy { $0 == " " || $0 == "\t" }
        }
        var cells: [NSRange] = []
        for index in 0..<(bounds.count - 1) {
            let cell = NSRange(location: bounds[index] + 1, length: bounds[index + 1] - bounds[index] - 1)
            let isEdge = index == 0 || index == bounds.count - 2
            if isEdge, isBlank(cell) { continue }
            cells.append(cell)
        }
        return (cells, pipes)
    }
}