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

    // MARK: The hidden |---| row

    /// Where the cursor goes when moved from `previous` to `location`, as "^".
    private func skip(_ text: String, to location: Int, from previous: Int) -> String? {
        let string = text as NSString
        guard let moved = TableEditing.adjustedCaret(location, from: previous, in: string,
                                                                 blockMap: BlockMap(text: string)) else { return nil }
        return string.replacingCharacters(in: NSRange(location: moved, length: 0), with: "^")
    }

    @Test func theCursorSkipsTheDelimiterRow() {
        let text = "| Name | Grade |\n| --- | --- |\n| Al | 1 |\n\nend"
        let delimiterColumn2 = 24, header = 2, body = 34
        // Down (or right) onto it: on to the same column of the first body row.
        #expect(skip(text, to: delimiterColumn2, from: 10) == "| Name | Grade |\n| --- | --- |\n| Al | 1^ |\n\nend")
        #expect(skip(text, to: 17, from: 16) == "| Name | Grade |\n| --- | --- |\n| Al^ | 1 |\n\nend")
        // Up (or left) onto it: back to the header.
        #expect(skip(text, to: delimiterColumn2, from: body) == "| Name | Grade^ |\n| --- | --- |\n| Al | 1 |\n\nend")
        #expect(skip(text, to: 18, from: header + 30) == "| Name^ | Grade |\n| --- | --- |\n| Al | 1 |\n\nend")
        // Anywhere else: nothing to do.
        #expect(skip(text, to: header, from: 0) == nil)
        #expect(skip(text, to: body, from: 0) == nil)
        #expect(skip("a\n| --- | --- |", to: 5, from: 0) == nil)  // not a table
    }

    @Test func outsideTheOuterPipesTheCursorSnapsIntoACell() {
        let text = "| Name | Grade |\n| --- | --- |\n| Al | 1 |"
        let bodyStart = 31, bodyEnd = 41
        // A click left or right of a row (or End): into the first / last cell.
        #expect(skip(text, to: bodyStart, from: 3) == "| Name | Grade |\n| --- | --- |\n| ^Al | 1 |")
        #expect(skip(text, to: bodyEnd, from: 3) == "| Name | Grade |\n| --- | --- |\n| Al | 1^ |")
        #expect(skip(text, to: 16, from: 36) == "| Name | Grade^ |\n| --- | --- |\n| Al | 1 |")
        #expect(skip("| a |  |\n|---|---|", to: 8, from: 2) == "| a | ^ |\n|---|---|")  // an empty cell: after its first space
        // Inside the pipes nothing changes.
        #expect(skip(text, to: bodyStart + 1, from: 3) == nil)
        #expect(skip(text, to: bodyEnd - 1, from: 3) == nil)
    }

    @Test func fromACellsOuterEdgeArrowsLeaveTheRow() {
        let text = "before\n| a | b |\n|---|---|\n| 1 | 2 |\nafter"
        // ← from the header's first cell: up to the line above.
        #expect(skip(text, to: 7, from: 9) == "before^\n| a | b |\n|---|---|\n| 1 | 2 |\nafter")
        // → from the last row's last cell: down to the line below.
        #expect(skip(text, to: 36, from: 35) == "before\n| a | b |\n|---|---|\n| 1 | 2 |\n^after")
        // → from the header's last cell: past the hidden row into the body.
        #expect(skip(text, to: 16, from: 15) == "before\n| a | b |\n|---|---|\n| 1^ | 2 |\nafter")
        // ← from the body's first cell: back over the hidden row to the header's end.
        #expect(skip(text, to: 27, from: 29) == "before\n| a | b^ |\n|---|---|\n| 1 | 2 |\nafter")
    }

    @Test func withoutBodyRowsTheCursorLeavesTheTableDownwards() {
        #expect(skip("| A |\n|---|\nnext", to: 8, from: 2) == "| A |\n|---|\n^next")
        #expect(skip("| A |\n|---|", to: 8, from: 2) == "| A^ |\n|---|")  // nowhere below: the header
    }

    @Test func backspaceAndDeleteDontRemoveThePipes() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |" as NSString
        let map = BlockMap(text: text)
        func blocked(_ location: Int, forward: Bool) -> Bool {
            let edit = TableEditing.editForDelete(forward: forward, in: text, selection: NSRange(location: location, length: 0), blockMap: map)
            if let edit { #expect(edit.isNoChange) }
            return edit != nil
        }
        #expect(blocked(5, forward: false))   // after the pipe between "a" and "b"
        #expect(blocked(4, forward: true))    // before it
        #expect(blocked(1, forward: false))   // after the row's first pipe
        #expect(!blocked(3, forward: false))  // deleting "a" is fine
        #expect(!blocked(7, forward: true))
        let plain = "a | b" as NSString
        #expect(TableEditing.editForDelete(forward: false, in: plain, selection: NSRange(location: 3, length: 0),
                                           blockMap: BlockMap(text: plain)) == nil)  // not a table
    }
}

struct TableNavigationTests {
    private let text = "| test | Column 2 |\n| --- | --- |\n|  |  |\n| afs |  |\n|  |  |" as NSString

    private func move(up: Bool, from location: Int) -> Int? {
        TableEditing.caretForVerticalMove(up: up, in: text, selection: NSRange(location: location, length: 0),
                                          blockMap: BlockMap(text: text))
    }

    /// The report: up from the first body row went to the other column's
    /// header, and the next down jumped back to the first column.
    @Test func upAndDownStayInTheColumn() {
        let firstBodyColumn1 = text.range(of: "|  |  |").location + 2   // after "| "
        let header1End = text.range(of: "test").upperBound
        #expect(move(up: true, from: firstBodyColumn1) == text.range(of: "test").location)
        #expect(move(up: false, from: header1End) == firstBodyColumn1)  // past the hidden row
        let afs = text.range(of: "afs")
        #expect(move(up: false, from: firstBodyColumn1) == afs.location)
        #expect(move(up: true, from: afs.upperBound) == firstBodyColumn1)  // an empty cell: its start
        // The place in the text is kept where it fits.
        #expect(move(up: true, from: afs.location + 2) == firstBodyColumn1)
        #expect(move(up: false, from: text.range(of: "test").location + 2) == firstBodyColumn1)
        // Column 2 stays column 2.
        let column2 = text.range(of: "Column 2")
        let body2 = move(up: false, from: column2.location)!
        #expect(TableEditing.table(at: body2, in: text, blockMap: BlockMap(text: text))?.position(of: body2)?.column == 1)
    }

    @Test func aboveTheHeaderAndBelowTheLastRowTheCursorLeaves() {
        #expect(move(up: true, from: 3) == nil)
        #expect(move(up: false, from: text.length - 2) == nil)
        #expect(move(up: true, from: 0) == nil)  // on the pipe: still the header row
    }

    @Test func shiftReturnInACellWritesABreak() {
        let location = text.range(of: "afs").upperBound
        let edit = TableEditing.editForLineBreak(in: text, selection: NSRange(location: location, length: 0),
                                                 blockMap: BlockMap(text: text))
        #expect(edit.map { $0.applied(to: text as String) }?.contains("| afs<br> |") == true)
        #expect(edit?.selectionAfter == NSRange(location: location + 4, length: 0))
        let plain = "a line" as NSString
        #expect(TableEditing.editForLineBreak(in: plain, selection: NSRange(location: 2, length: 0),
                                              blockMap: BlockMap(text: plain)) == nil)
        // Shown dimmed, as a line break.
        let cell = "| a<br>b |\n|---|" as NSString
        #expect(MarkdownStyler.spans(in: cell, blocks: BlockMap(text: cell).blocks)
            .contains { $0.style == .lineBreak && cell.substring(with: $0.range) == "<br>" })
    }
}
