// Tests for editing tables: finding them, rows and columns, Tab and Return.
// Pipes are table syntax here, so the cursor is marked with "^" and a selection
// with "[[" and "]]".

import Foundation
import Testing
@testable import DocTypeCore

struct TableEditingTests {
    private func parse(_ marked: String) -> (NSString, NSRange) {
        let string = marked as NSString
        let cursor = string.range(of: "^")
        if cursor.location != NSNotFound {
            return (string.replacingCharacters(in: cursor, with: "") as NSString, NSRange(location: cursor.location, length: 0))
        }
        let open = string.range(of: "[[").location, close = string.range(of: "]]").location
        let text = string.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        return (text as NSString, NSRange(location: open, length: close - open - 2))
    }

    private func show(_ edit: TextEdit?, on text: NSString) -> String? {
        guard let edit else { return nil }
        let result = edit.applied(to: text as String) as NSString
        let after = edit.selectionAfter
        if after.length == 0 { return result.replacingCharacters(in: after, with: "^") }
        let closed = result.replacingCharacters(in: NSRange(location: after.upperBound, length: 0), with: "]]") as NSString
        return closed.replacingCharacters(in: NSRange(location: after.location, length: 0), with: "[[")
    }

    private func run(_ operation: TableOperation, _ marked: String, maximumColumns: Int = .max) -> String? {
        let (text, selection) = parse(marked)
        return show(TableEditing.edit(operation, at: selection.location, in: text, blockMap: BlockMap(text: text),
                                      maximumColumns: maximumColumns), on: text)
    }

    private let table = "intro\n\n| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nafter"

    // MARK: Finding

    @Test func findsTheTableAroundTheCursor() {
        let text = table as NSString
        let found = TableEditing.table(at: text.range(of: "2").location, in: text, blockMap: BlockMap(text: text))
        #expect(found?.lines.count == 4)
        #expect(found?.columnCount == 2)
        #expect(found?.position(of: text.range(of: "2").location).map { [$0.row, $0.column] } == [2, 1])
        #expect(TableEditing.table(at: 2, in: text, blockMap: BlockMap(text: text)) == nil)  // "intro"
        let code = "```\n| A | B |\n|---|---|\n```" as NSString
        #expect(TableEditing.table(at: 6, in: code, blockMap: BlockMap(text: code)) == nil)
        let noDelimiter = "| A | B |\n| 1 | 2 |" as NSString
        #expect(TableEditing.table(at: 3, in: noDelimiter, blockMap: BlockMap(text: noDelimiter)) == nil)
    }

    // MARK: Rows and columns

    @Test func addingRows() {
        #expect(run(.addRowBelow, "| A | B |\n|---|---|\n| 1^ | 2 |") == "| A | B |\n|---|---|\n| 1 | 2 |\n| ^ |  |")
        #expect(run(.addRowAbove, "| A | B |\n|---|---|\n| 1 | 2^ |") == "| A | B |\n|---|---|\n|  | ^ |\n| 1 | 2 |")
        #expect(run(.addRowAbove, "| A^ | B |\n|---|---|\n| 1 | 2 |") == "| A | B |\n|---|---|\n| ^ |  |\n| 1 | 2 |")  // not above the header
    }

    @Test func addingColumnsKeepsCellsAndIndentation() {
        #expect(run(.addColumnRight, "| A | B |\n|---|:-:|\n| 1^ | 2 |") == "| A |  | B |\n|---| --- |:-:|\n| 1 | ^ | 2 |")
        #expect(run(.addColumnLeft, "  a | b\n  --|--\n  ^1 | 2") == "  |  |a | b|\n  | --- |--|--|\n  | ^ |1 | 2|")
    }

    @Test func columnsStopAtTheMaximum() {
        let full = "| A | B | C |\n|---|---|---|\n| 1^ | 2 | 3 |"
        #expect(run(.addColumnRight, full, maximumColumns: 3) == nil)
        #expect(run(.addColumnLeft, full, maximumColumns: 3) == nil)
        #expect(run(.addColumnRight, full, maximumColumns: 4) != nil)
        #expect(run(.addRowBelow, full, maximumColumns: 3) != nil)  // rows aren't limited
        #expect(run(.deleteColumn, full, maximumColumns: 2) == "| B | C |\n|---|---|\n| ^2 | 3 |")  // nor making it narrower
    }

    @Test func deletingRowsAndColumns() {
        #expect(run(.deleteRow, "| A | B |\n|---|---|\n| 1^ | 2 |\n| 3 | 4 |") == "| A | B |\n|---|---|\n| ^3 | 4 |")
        #expect(run(.deleteRow, "| A^ | B |\n|---|---|\n| 1 | 2 |") == nil)  // the header stays
        #expect(run(.deleteColumn, "| A | B |\n|---|---|\n| 1^ | 2 |") == "| B |\n|---|\n| ^2 |")
        #expect(run(.deleteColumn, "| A |\n|---|\n| 1^ |") == nil)  // the last column stays
    }

    @Test func aligningAColumn() {
        #expect(run(.align(.center), "| A | B^ |\n|---|---|") == "| A | ^B |\n|---| :---: |")
        #expect(run(.align(.right), "| A^ | B |\n|---|---|")?.contains("| ---: |---|") == true)
    }

    @Test func shortRowsAreFilledUp() {
        #expect(run(.addColumnRight, "| A | B |\n|---|---|\n| 1^ |") == "| A |  | B |\n|---| --- |---|\n| 1 | ^ |  |")
    }
    @Test func insertingATableSelectsTheFirstHeader() {
        let (text, selection) = parse("Notes^")
        #expect(show(TableEditing.insertTable(in: text, selection: selection), on: text)
                == "Notes\n\n| [[Column 1]] | Column 2 |\n| --- | --- |\n|  |  |")
        let (empty, cursor) = parse("^")
        #expect(show(TableEditing.insertTable(in: empty, selection: cursor), on: empty)
                == "| [[Column 1]] | Column 2 |\n| --- | --- |\n|  |  |")
    }

    /// Right under a list item or a quote, a table would be part of that block.
    @Test func insertingATableKeepsABlankLineFromTheTextAround() {
        let (list, end) = parse("- [ ] task\n^")
        #expect(show(TableEditing.insertTable(in: list, selection: end), on: list)
                == "- [ ] task\n\n| [[Column 1]] | Column 2 |\n| --- | --- |\n|  |  |")
        let (between, cursor) = parse("above\n^\nbelow")
        #expect(show(TableEditing.insertTable(in: between, selection: cursor), on: between)
                == "above\n\n| [[Column 1]] | Column 2 |\n| --- | --- |\n|  |  |\n\nbelow")
        let (spaced, blank) = parse("above\n\n^\n\nbelow")
        #expect(show(TableEditing.insertTable(in: spaced, selection: blank), on: spaced)
                == "above\n\n| [[Column 1]] | Column 2 |\n| --- | --- |\n|  |  |\n\nbelow")
    }


    // MARK: Moving between cells

    private let grid = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 |  |" as NSString
    private func target(_ key: TableEditing.CellKey, _ row: Int, _ column: Int, in text: NSString? = nil) -> TableEditing.CellTarget {
        let text = text ?? grid
        let table = TableEditing.table(at: 0, in: text, blockMap: BlockMap(text: text))!
        return TableEditing.target(of: key, fromRow: row, column: column, in: table, text: text)
    }

    @Test func arrowsGoToTheNeighboringCellAndOutAtTheEdges() {
        #expect(target(.right, 0, 0) == .cell(row: 0, column: 1))
        #expect(target(.right, 0, 1) == .cell(row: 2, column: 0))  // past the hidden |---| row
        #expect(target(.left, 2, 0) == .cell(row: 0, column: 1))
        #expect(target(.left, 0, 0) == .leaveAbove)
        #expect(target(.right, 3, 1) == .leaveBelow)
        #expect(target(.down, 0, 1) == .cell(row: 2, column: 1))
        #expect(target(.up, 2, 1) == .cell(row: 0, column: 1))
        #expect(target(.up, 0, 1) == .leaveAbove)
        #expect(target(.down, 3, 0) == .leaveBelow)
    }

    @Test func tabAddsARowAfterTheLastCellAndShiftTabStopsAtTheFirst() {
        #expect(target(.tab, 2, 1) == .cell(row: 3, column: 0))
        #expect(target(.tab, 3, 1) == .addRow(column: 0))
        #expect(target(.backtab, 0, 0) == .cell(row: 0, column: 0))
        #expect(target(.backtab, 3, 0) == .cell(row: 2, column: 1))
    }

    @Test func columnAlignmentComesFromTheDelimiterRow() {
        let text = "| a | b | c |\n|:--|:-:|--:|" as NSString
        let table = TableEditing.table(at: 0, in: text, blockMap: BlockMap(text: text))!
        #expect((0..<3).map { TableEditing.alignment(ofColumn: $0, in: table, text: text) } == [.left, .center, .right])
        #expect(TableEditing.alignment(ofColumn: 5, in: table, text: text) == .left)
    }

    @Test func returnGoesDownAddsARowAndLeavesOnAnEmptyLastRow() {
        #expect(target(.newline, 0, 1) == .cell(row: 2, column: 1))
        #expect(target(.newline, 3, 1) == .addRow(column: 1))  // the last row has text
        let empty = "| A | B |\n|---|---|\n| 1 | 2 |\n|  |  |" as NSString
        #expect(target(.newline, 3, 0, in: empty) == .removeLastRowAndLeave)
        let edit = TableEditing.editRemovingLastRow(of: TableEditing.table(at: 0, in: empty, blockMap: BlockMap(text: empty))!, in: empty)
        #expect(edit.applied(to: empty as String) == "| A | B |\n|---|---|\n| 1 | 2 |\n")
        #expect(edit.selectionAfter == NSRange(location: empty.length - 7, length: 0))
        // The header row is never removed.
        let headerOnly = "|  |  |\n|---|---|" as NSString
        #expect(target(.newline, 0, 0, in: headerOnly) == .addRow(column: 0))
    }
}

struct TableCellTextTests {
    @Test func lineBreaksAndPipesShowAsTheyRead() {
        let cell = TableCellText(markdown: "one<br>two<BR/>three \\| four")
        #expect(cell.editorText == "one\ntwo\nthree | four")
        #expect(TableCellText(markdown: "a\\|b").editorText == "a|b")
        #expect(TableCellText(markdown: "<br><br>").editorText == "\n\n")
    }

    @Test func editorTextIsWrittenBackAsMarkdown() {
        #expect(TableCellText.markdown(fromEditorText: "one\ntwo") == "one<br>two")
        #expect(TableCellText.markdown(fromEditorText: "a|b") == "a\\|b")
        #expect(TableCellText.markdown(fromEditorText: "a\\|b") == "a\\|b")  // already escaped
        #expect(TableCellText.markdown(fromEditorText: "x\r\ny") == "x<br>y")
        // Round trip.
        let markdown = "one<br>two \\| three<br>"
        #expect(TableCellText.markdown(fromEditorText: TableCellText(markdown: markdown).editorText) == markdown)
    }

    @Test func offsetsMapBothWays() {
        let cell = TableCellText(markdown: "ab<br>cd\\|e")  // editor: "ab\ncd|e"
        #expect(cell.editorText == "ab\ncd|e")
        #expect(cell.markdownOffset(forEditorOffset: 3) == 6)   // "c"
        #expect(cell.markdownOffset(forEditorOffset: 5) == 8)   // the "\\|"
        #expect(cell.markdownOffset(forEditorOffset: 7) == 11)  // the end
        #expect(cell.editorOffset(forMarkdownOffset: 6) == 3)
        #expect(cell.editorOffset(forMarkdownOffset: 4) == 2)   // inside "<br>": before it
        #expect(cell.editorRange(forMarkdownRange: NSRange(location: 6, length: 2)) == NSRange(location: 3, length: 2))
        #expect(cell.editorRange(forMarkdownRange: NSRange(location: 0, length: 4)) == NSRange(location: 0, length: 3))
    }
}
