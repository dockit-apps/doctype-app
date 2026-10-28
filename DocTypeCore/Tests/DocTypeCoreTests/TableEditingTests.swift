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

    private func run(_ operation: TableOperation, _ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return show(TableEditing.edit(operation, at: selection.location, in: text, blockMap: BlockMap(text: text)), on: text)
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

    // MARK: Tab and Return

    private func tab(_ marked: String, forward: Bool = true) -> String? {
        let (text, selection) = parse(marked)
        return show(TableEditing.editForTab(forward: forward, in: text, selection: selection, blockMap: BlockMap(text: text)), on: text)
    }

    private func newline(_ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return show(TableEditing.editForNewline(in: text, selection: selection, blockMap: BlockMap(text: text)), on: text)
    }

    @Test func tabSelectsTheNextCellAndSkipsTheDelimiterRow() {
        #expect(tab("| A^ | Bee |\n|---|---|\n| 1 | 2 |") == "| A | [[Bee]] |\n|---|---|\n| 1 | 2 |")
        #expect(tab("| A | Bee^ |\n|---|---|\n| 1 | 2 |") == "| A | Bee |\n|---|---|\n| [[1]] | 2 |")
        #expect(tab("| A | B |\n|---|---|\n| ^1 | 2 |", forward: false) == "| A | [[B]] |\n|---|---|\n| 1 | 2 |")
        #expect(tab("| A | B |\n|---|---|\n|  | ^ |", forward: false) == "| A | B |\n|---|---|\n| ^ |  |")  // empty cell: a cursor
    }

    @Test func tabInTheLastCellAddsARow() {
        #expect(tab("| A | B |\n|---|---|\n| 1 | 2^ |") == "| A | B |\n|---|---|\n| 1 | 2 |\n| ^ |  |")
    }

    @Test func shiftTabInTheFirstCellStaysPut() {
        #expect(tab("| ^A | B |\n|---|---|", forward: false) == "| ^A | B |\n|---|---|")
        #expect(tab("not a table^") == nil)
    }

    @Test func returnMovesDownAndAddsARowAtTheEnd() {
        #expect(newline("| A | B^ |\n|---|---|\n| 1 | 2 |") == "| A | B |\n|---|---|\n| 1 | 2^ |")
        #expect(newline("| A | B |\n|---|---|\n| 1 | 2^ |") == "| A | B |\n|---|---|\n| 1 | 2 |\n|  | ^ |")
        #expect(newline("| A | [[Bee]] |\n|---|---|\n| 1 | 2 |") == "| A | Bee |\n|---|---|\n| 1 | 2^ |")  // after Tab
    }

    @Test func returnOnAnEmptyLastRowLeavesTheTable() {
        #expect(newline("| A | B |\n|---|---|\n| 1 | 2 |\n| ^ |  |") == "| A | B |\n|---|---|\n| 1 | 2 |\n^")
        #expect(newline("text^") == nil)
    }

    // MARK: Inserting

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
}
