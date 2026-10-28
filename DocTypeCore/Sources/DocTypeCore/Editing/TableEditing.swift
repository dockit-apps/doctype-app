// Editing GFM tables as tables: inserting one, adding and deleting rows and
// columns, aligning a column, and moving between cells with Tab and Return.
//
// Behavior, and why (spreadsheet and Typora conventions):
// - Tab selects the next cell's text (typing replaces it), Shift-Tab the
//   previous one; Tab in the last cell adds a row. Inside a table Tab never
//   types a tab character, which would only break the row.
// - Return moves to the same column in the next row, adding a row at the end;
//   Return on an empty last row removes it and leaves the table, like an empty
//   list item ends a list. A line break can't be part of a cell in markdown anyway.
// - Structural edits (columns, alignment) rewrite each row as `| a | b |`,
//   keeping every cell's text, spacing and the row's indentation; adding or
//   deleting a row only touches that row. The header row can't be deleted
//   (GFM needs it), and neither can a table's last column.
// Alternatives considered: re-formatting the whole table to padded columns on
// every edit (makes diffs noisy, and the editor already lines columns up), and
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
    }

    // MARK: - Where the cursor may be

    /// Where the cursor goes instead of `location` (moved there from `previous`)
    /// in a table, or nil to leave it. Typing at these spots would break the table:
    /// - the hidden `|---|` row is skipped (see caretSkippingDelimiterRow);
    /// - outside a row's outer pipes (left of it, or End / right of it) the cursor
    ///   snaps into the first or last cell, since the pipes are invisible;
    /// - from a cell's outer edge, ← / → once more leave the row.
    public static func adjustedCaret(_ location: Int, from previous: Int, in text: NSString,
                                     blockMap: BlockMap) -> Int? {
        if let skipped = caretSkippingDelimiterRow(location, from: previous, in: text, blockMap: blockMap) { return skipped }
        guard let edge = rowEdge(location, from: previous, in: text, blockMap: blockMap) else { return nil }
        guard let leave = edge.leave else { return edge.snap }
        // Leaving the row: the spot reached may be in the table too.
        return caretSkippingDelimiterRow(leave, from: previous, in: text, blockMap: blockMap)
            ?? rowEdge(leave, from: leave, in: text, blockMap: blockMap)?.snap ?? leave
    }

    /// For a cursor outside a table row's outer pipes: the cell edge to snap to,
    /// and where to go instead when ← / → is pressed at that edge (to leave the row).
    private static func rowEdge(_ location: Int, from previous: Int, in text: NSString,
                                blockMap: BlockMap) -> (snap: Int, leave: Int?)? {
        guard location <= text.length else { return nil }
        let line = lineContaining(location, in: text)
        let (cells, pipes) = TableRowParsing.cells(in: line, of: text)
        guard let first = cells.first, let last = cells.last, let firstPipe = pipes.first, let lastPipe = pipes.last,
              let table = table(at: location, in: text, blockMap: blockMap), table.lines[1] != line else { return nil }
        let start = contentRange(of: first, in: text).location
        let end = contentRange(of: last, in: text).upperBound
        let previousOnLine = previous >= line.location && previous <= line.upperBound
        if firstPipe < first.location, location <= firstPipe {
            let atEdge = previousOnLine && previous > firstPipe && previous <= start && location < previous
            let above = line.location > 0 ? lineContaining(line.location - 1, in: text).upperBound : nil
            return (start, atEdge ? above : nil)
        }
        if lastPipe >= last.upperBound, location > lastPipe {
            let atEdge = previousOnLine && previous >= end && previous <= lastPipe && location > previous
            var lineEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: line)
            return (end, atEdge && lineEnd > line.upperBound ? lineEnd : nil)
        }
        return nil
    }

    /// Where the cursor goes instead of `location` when that's on a table's
    /// hidden `|---|` row: on to the same column of the first body row when
    /// moving down or right from `previous`, back to the header when moving up
    /// or left. Nil when `location` isn't on such a row.
    static func caretSkippingDelimiterRow(_ location: Int, from previous: Int, in text: NSString,
                                                 blockMap: BlockMap) -> Int? {
        guard location <= text.length else { return nil }
        let line = lineContaining(location, in: text)
        guard isDelimiterRow(line, in: text),
              let table = table(at: location, in: text, blockMap: blockMap), table.lines[1] == line,
              let (_, column) = table.position(of: location) else { return nil }
        let isMovingDown = location >= previous
        if isMovingDown, table.lines.count == 2 {
            // No body rows: on to the line after the table, if there is one.
            var lineEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: line)
            if lineEnd > line.upperBound { return lineEnd }
        }
        let row = isMovingDown && table.lines.count > 2 ? 2 : 0
        let cells = table.cells[row]
        guard !cells.isEmpty else { return table.lines[row].upperBound }
        return contentRange(of: cells[min(column, cells.count - 1)], in: text).upperBound
    }

    // MARK: - Tab and Return

    /// Tab: select the next cell's text (Shift-Tab: the previous one), adding a
    /// row after the last cell. Nil outside tables; a no-change edit at the very
    /// first cell, so Shift-Tab there does nothing instead of leaving the editor.
    public static func editForTab(forward: Bool, in text: NSString, selection: NSRange, blockMap: BlockMap) -> TextEdit? {
        guard let table = table(at: selection.location, in: text, blockMap: blockMap),
              let (row, column) = table.position(of: selection.location) else { return nil }
        var cells: [(row: Int, column: Int)] = []
        for (index, rowCells) in table.cells.enumerated() where index != 1 {
            cells += rowCells.indices.map { (index, $0) }
        }
        let current = cells.firstIndex { $0.row == max(row == 1 ? 2 : row, 0) && $0.column == column } ?? 0
        let next = current + (forward ? 1 : -1)
        if next < 0 { return moveSelection(from: selection, to: selection) }
        if next >= cells.count {
            // From the start of the last row, the new row's cursor lands in its first cell.
            return edit(.addRowBelow, at: table.lines.last!.location, in: text, blockMap: blockMap)
        }
        let target = table.cells[cells[next].row][cells[next].column]
        return moveSelection(from: selection, to: contentRange(of: target, in: text))
    }

    /// ↑ / ↓ in a table: the same column one row up or down, skipping the hidden
    /// `|---|` row, at the same place in the cell's text where it fits. Nil
    /// outside tables, above the header and below the last row (the cursor
    /// then leaves the table as usual). Moving by x position instead, as text
    /// views do, drifted between columns: the hidden row has no width to aim at.
    public static func caretForVerticalMove(up: Bool, in text: NSString, selection: NSRange, blockMap: BlockMap) -> Int? {
        guard selection.length == 0, let table = table(at: selection.location, in: text, blockMap: blockMap),
              let (row, column) = table.position(of: selection.location), row != 1 else { return nil }
        let target = up ? (row == 2 ? 0 : row - 1) : (row == 0 ? 2 : row + 1)
        guard target >= 0, target < table.lines.count, column < table.cells[row].count else { return nil }
        let from = contentRange(of: table.cells[row][column], in: text)
        let offset = min(max(selection.location - from.location, 0), from.length)
        let cells = table.cells[target]
        guard !cells.isEmpty else { return table.lines[target].location }
        let to = contentRange(of: cells[min(column, cells.count - 1)], in: text)
        return to.location + min(offset, to.length)
    }

    /// Shift-Return or Option-Return in a cell: a line break, written `<br>` as
    /// on GitHub, since a real one would end the row. Nil outside tables.
    public static func editForLineBreak(in text: NSString, selection: NSRange, blockMap: BlockMap) -> TextEdit? {
        let line = lineContaining(selection.location, in: text)
        guard selection.upperBound <= line.upperBound,
              let table = table(at: selection.location, in: text, blockMap: blockMap),
              let (row, _) = table.position(of: selection.location), row != 1 else { return nil }
        return TextEdit(range: selection, replacement: "<br>",
                        selectionAfter: NSRange(location: selection.location + 4, length: 0))
    }

    /// Return in a table row: the same column one row down, adding a row at the
    /// end; on an empty last row, removes it and leaves the table. Also with a
    /// cell's text selected (as Tab leaves it), like in a spreadsheet.
    public static func editForNewline(in text: NSString, selection: NSRange, blockMap: BlockMap) -> TextEdit? {
        let line = lineContaining(selection.location, in: text)
        guard selection.upperBound <= line.upperBound,
              let table = table(at: selection.location, in: text, blockMap: blockMap),
              let (row, column) = table.position(of: selection.location), row != 1 else { return nil }
        let isLast = row == table.lines.count - 1
        if isLast, row >= 2, table.cells[row].allSatisfy({ text.substring(with: $0).trimmingCharacters(in: .whitespaces).isEmpty }) {
            let line = table.lines[row]
            return TextEdit(range: line, replacement: "", selectionAfter: NSRange(location: line.location, length: 0))
        }
        if isLast {
            return edit(.addRowBelow, at: selection.location, in: text, blockMap: blockMap)
        }
        let nextRow = row == 0 ? 2 : row + 1
        let cells = table.cells[nextRow]
        let target = cells.isEmpty ? NSRange(location: table.lines[nextRow].location, length: 0)
            : contentRange(of: cells[min(column, cells.count - 1)], in: text)
        return moveSelection(from: selection, to: NSRange(location: target.upperBound, length: 0))
    }

    /// Backspace right after a cell's pipe (Delete right before one) would merge
    /// two cells or break the row, since the pipes are invisible: in a table it
    /// does nothing (a no-change edit). Nil everywhere else.
    public static func editForDelete(forward: Bool, in text: NSString, selection: NSRange, blockMap: BlockMap) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let target = forward ? selection.location : selection.location - 1
        guard target >= 0, target < text.length, text.character(at: target) == 124,  // "|"
              table(at: selection.location, in: text, blockMap: blockMap) != nil,
              TableRowParsing.cells(in: lineContaining(target, in: text), of: text).pipes.contains(target)
        else { return nil }
        return moveSelection(from: selection, to: selection)
    }

    /// An edit that changes nothing but the selection.
    private static func moveSelection(from selection: NSRange, to target: NSRange) -> TextEdit {
        TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selectionAfter: target)
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
