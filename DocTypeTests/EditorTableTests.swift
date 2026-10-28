// Tables in a real editor: drawn as a grid (wrapped cells, `<br>` as a line
// break, rows as tall as their tallest cell), and edited one cell at a time in
// the cell editor: typing, Shift-Return, the arrow keys, Tab and Return, undo
// (one history with the note's), the "+" buttons and the context menu.

import AppKit
import DocTypeCore
import Foundation
import Testing
@testable import DocType

@MainActor
struct EditorTableTests {
    /// An editor in a window, showing `Note.md` with `text`, laid out, with the
    /// keyboard in the note.
    private func editor(showing text: String, width: CGFloat = 600) async throws -> (EditorController, URL, NSWindow) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeTableTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appending(path: "Note.md"), atomically: true, encoding: .utf8)
        let controller = EditorController()
        controller.library = Library(root: folder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.scrollView
        #expect(await controller.open("Note.md"))
        window.makeFirstResponder(controller.textView)
        layOut(controller.textView)
        return (controller, folder, window)
    }

    private func layOut(_ textView: NSTextView) {
        if let layout = textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
    }

    /// The drawn layout of the table row whose line contains `piece`.
    private func row(containing piece: String, in editor: EditorController) -> TableRowLayout? {
        let location = (editor.textView.string as NSString).range(of: piece).location
        guard location != NSNotFound else { return nil }
        return editor.textView.textStorage?.attribute(EditorTheme.tableRowKey, at: location, effectiveRange: nil) as? TableRowLayout
    }

    /// Where the cell holding `piece` starts (just after its opening pipe).
    private func cell(_ piece: String, in editor: EditorController) -> Int {
        let text = editor.textView.string as NSString
        let location = text.range(of: piece).location
        guard location != NSNotFound else {
            Issue.record("\(piece) isn't in the note")
            return 0
        }
        return text.range(of: "|", options: .backwards, range: NSRange(location: 0, length: location)).upperBound
    }

    private func type(_ text: String, in editor: EditorController) {
        let cellEditor = editor.tableCells.editor
        cellEditor.insertText(text, replacementRange: cellEditor.selectedRange())
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// The note's undo manager, grouped by hand: each `step` is one group, as
    /// the run loop makes one for a key press that registers undo (while other
    /// tests run, the run loop doesn't end its groups in time). A key press
    /// that must not start a step runs outside any group, where registering
    /// undo would raise.
    private func groupUndoByHand(_ editor: EditorController) throws -> UndoManager {
        let undoManager = try #require(editor.textView.undoManager)
        #expect(undoManager.groupingLevel == 0)
        undoManager.groupsByEvent = false
        return undoManager
    }

    /// A key press (or command) that is a step of its own in the undo history.
    private func step(_ undoManager: UndoManager, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }

    /// ⌘Z ("undo:") or Shift-⌘Z ("redo:") as the Edit menu sends it: to the
    /// focused view and up from there (the window handles it).
    private func press(_ action: String, in window: NSWindow) {
        #expect(window.firstResponder?.tryToPerform(NSSelectorFromString(action), with: nil) == true)
    }

    // MARK: Drawing

    @Test func tablesAreDrawnAsAGridWithLineBreaksAndRowsAsTallAsTheirTallestCell() async throws {
        let text = "| Name | Notes |\n| --- | :---: |\n| Al | one<br>two<br>three |\n| Bo | x |\n\nafter"
        let (editor, folder, _) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(editor.textView.string == text)  // drawn differently, stored as it was
        let header = try #require(row(containing: "Name", in: editor))
        let tall = try #require(row(containing: "Al", in: editor))
        let short = try #require(row(containing: "Bo", in: editor))
        #expect(tall.cells.map(\.text.string) == ["Al", "one\ntwo\nthree"])
        #expect(tall.columnLines == header.columnLines)  // columns line up across rows
        let line = EditorTheme.emptyCellHeight
        #expect(tall.height > short.height + 1.5 * line)  // three lines against one
        #expect(abs(short.height - (line + 2 * EditorTheme.tableRowPadding).rounded(.up)) < 1)
        // A cell's paragraph keeps its column's alignment.
        let style = tall.cells[1].text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.alignment == .center)
    }

    @Test func longCellsWrapInsideTheirColumn() async throws {
        let long = String(repeating: "word ", count: 40)
        let text = "| A | B |\n| --- | --- |\n| short | \(long)|\n\nafter"
        let (editor, folder, _) = try await editor(showing: text, width: 400)
        defer { try? FileManager.default.removeItem(at: folder) }
        let row = try #require(row(containing: "short", in: editor))
        let table = try #require(row.columnLines.last)
        #expect(table <= 400)  // fits the editor instead of running past it
        #expect(row.height > 3 * EditorTheme.emptyCellHeight)  // the long cell wrapped
    }

    // MARK: Typing in a cell

    @Test func typingInACellWritesTheNoteAndShiftReturnGrowsTheRow() async throws {
        let text = "| test | Column 2 |\n| --- | --- |\n| test |  |"
        let (editor, folder, _) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cells = editor.tableCells!
        let cellEditor = cells.editor

        let body = (editor.textView.string as NSString).range(of: "| test |  |").location + 1
        #expect(cells.begin(cellAt: body, placing: .end))
        #expect(cells.isEditing)
        #expect(cellEditor.window?.firstResponder === cellEditor)
        #expect(cellEditor.string == "test")
        let before = try #require(row(containing: "| test |  |", in: editor)).height

        // The report: after Shift-Return the cursor was drawn a line too high.
        // Here the editor's own cursor is on the new, second line.
        cellEditor.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        #expect(editor.textView.string == "| test | Column 2 |\n| --- | --- |\n| test<br> |  |")
        #expect(cellEditor.isCaretOnLastLine && !cellEditor.isCaretOnFirstLine)
        let grown = try #require(row(containing: "| test<br>", in: editor)).height
        #expect(grown > before + EditorTheme.emptyCellHeight * 0.8)
        #expect(cellEditor.frame.height > EditorTheme.emptyCellHeight * 1.8)

        type("more", in: editor)
        #expect(editor.textView.string.contains("| test<br>more |  |"))
        // Deleting the line again: the row shrinks back.
        for _ in 0..<5 { cellEditor.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
        #expect(editor.textView.string.contains("| test |  |"))
        #expect(try #require(row(containing: "| test |  |", in: editor)).height == before)

        // A "|" typed in a cell is escaped in the markdown.
        type(" a|b", in: editor)
        #expect(editor.textView.string.contains("| test a\\|b |  |"))
    }

    // MARK: Undo

    @Test func undoInATableGoesBackThroughEverythingInOrderWithoutLeavingIt() async throws {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\nafter"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cells = editor.tableCells!
        let textView = editor.textView
        let undoManager = try groupUndoByHand(editor)

        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        step(undoManager) { textView.insertText("!", replacementRange: textView.selectedRange()) }  // in the note
        #expect(cells.begin(cellAt: cell("2", in: editor), placing: .end))
        step(undoManager) { type("3", in: editor) }
        type("4", in: editor)  // typing on: the same step
        step(undoManager) { #expect(cells.move(.newline)) }  // Return in the last row adds a row
        step(undoManager) { type("x", in: editor) }
        let typed = "| A | B |\n| --- | --- |\n| 1 | 234 |\n|  | x |\n\nafter!"
        #expect(textView.string == typed)

        // Each ⌘Z, still in the table, undoes the last thing done, and the
        // cell where it was opens.
        let states = [
            "| A | B |\n| --- | --- |\n| 1 | 234 |\n|  |  |\n\nafter!",
            "| A | B |\n| --- | --- |\n| 1 | 234 |\n\nafter!",
            text + "!",
        ]
        for state in states {
            press("undo:", in: window)
            #expect(textView.string == state)
            try await waitUntil { cells.isEditing }
            #expect(window.firstResponder === cells.editor)
        }
        // The cursor is where that typing was: after "2".
        #expect(cells.cellLocation == cell("2", in: editor))
        #expect(cells.editor.selectedRange() == NSRange(location: 1, length: 0))

        // One more leaves the table: the note's typing.
        press("undo:", in: window)
        #expect(textView.string == text)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!cells.isEditing)
        #expect(window.firstResponder === textView)

        // Shift-⌘Z redoes it all, in order, opening each change's cell.
        press("redo:", in: window)
        #expect(textView.string == text + "!")
        for state in states.reversed().dropFirst() + [typed] {
            press("redo:", in: window)
            #expect(textView.string == state)
            try await waitUntil { cells.isEditing }
            #expect(window.firstResponder === cells.editor)
        }
        #expect(cells.cellLocation == cell("x", in: editor))
    }

    @Test func keyPressesInARowAreOneUndoStepAndAFormatCommandIsItsOwn() async throws {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\nafter"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cells = editor.tableCells!
        let undoManager = try groupUndoByHand(editor)

        #expect(cells.begin(cellAt: cell("1", in: editor), placing: .end))
        step(undoManager) { type("a", in: editor) }
        type("b", in: editor)
        cells.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))  // the Delete key, back over it
        cells.editor.setSelectedRange(NSRange(location: 0, length: 0))
        step(undoManager) { type("z", in: editor) }  // typing somewhere else: a new step
        step(undoManager) { editor.format { Formatting.toggle(.strong, in: $0, selection: $1) } }  // its own step
        #expect(editor.textView.string == "| A | B |\n| --- | --- |\n| **z1a** | 2 |\n\nafter")

        for state in ["| z1a | 2 |", "| 1a | 2 |", "| 1 | 2 |"] {
            press("undo:", in: window)
            #expect(editor.textView.string == "| A | B |\n| --- | --- |\n\(state)\n\nafter")
            try await waitUntil { cells.isEditing }
        }
    }

    @Test func undoFromOutsideTheTableOpensTheCellWhereTheChangeWas() async throws {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\nafter"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cells = editor.tableCells!
        #expect(cells.begin(cellAt: cell("1", in: editor), placing: .end))
        type("0", in: editor)
        type("0", in: editor)
        #expect(editor.textView.string.contains("| 100 | 2 |"))

        cells.end(placingCursorAt: (editor.textView.string as NSString).range(of: "after").location)
        #expect(window.firstResponder === editor.textView)
        press("undo:", in: window)
        #expect(editor.textView.string == text)
        try await waitUntil { cells.isEditing }
        #expect(cells.cellLocation == cell("1", in: editor))
        #expect(cells.editor.selectedRange() == NSRange(location: 1, length: 0))  // where "00" was typed
        press("redo:", in: window)
        #expect(editor.textView.string.contains("| 100 | 2 |"))
        try await waitUntil { cells.isEditing }
        #expect(cells.editor.selectedRange() == NSRange(location: 1, length: 2))  // "00" is back, selected
        press("undo:", in: window)  // and back again
        #expect(editor.textView.string == text)
    }

    // MARK: Moving between cells

    @Test func arrowsMoveAlongACellsLinesThenBetweenCellsAndOutOfTheTable() async throws {
        let text = "above\n\n| A | B |\n| --- | --- |\n| one<br>two | 2 |\n\nbelow"
        let (editor, folder, _) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cells = editor.tableCells!
        let cellEditor = cells.editor

        #expect(cells.begin(cellAt: cell("one", in: editor), placing: .end))  // after "two"
        cellEditor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(cells.cellLocation == cell("one", in: editor))  // still in the cell, on its first line
        #expect(cellEditor.isCaretOnFirstLine)
        cellEditor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(cells.cellLocation == cell("A", in: editor))  // the header above
        cellEditor.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
        cellEditor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(cells.cellLocation == cell("B", in: editor))
        #expect(cellEditor.selectedRange() == NSRange(location: 0, length: 0))
        cellEditor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(cells.cellLocation == cell("2", in: editor))
        cellEditor.doCommand(by: #selector(NSResponder.moveDown(_:)))  // out below
        #expect(!cells.isEditing)
        #expect(editor.textView.window?.firstResponder === editor.textView)
        #expect(editor.textView.selectedRange().location == (editor.textView.string as NSString).range(of: "\n\nbelow").location + 1)

        #expect(cells.begin(cellAt: cell("A", in: editor), placing: .start))
        cellEditor.doCommand(by: #selector(NSResponder.moveLeft(_:)))  // out above
        #expect(!cells.isEditing)
        #expect(editor.textView.selectedRange().location == 6)  // the blank line above the table
    }

    @Test func tabAndReturnMoveThroughCellsAndAddRows() async throws {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let (editor, folder, _) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cells = editor.tableCells!
        let cellEditor = cells.editor

        #expect(cells.begin(cellAt: cell("A", in: editor), placing: .end))
        cellEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(cells.cellLocation == cell("B", in: editor))
        #expect(cellEditor.selectedRange() == NSRange(location: 0, length: 1))  // its text, selected
        cellEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(cells.cellLocation == cell("2", in: editor))
        cellEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))  // the last cell: a new row
        #expect(editor.textView.string == text + "\n|  |  |")
        #expect(cells.isEditing)
        cellEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))  // an empty last row: leave
        #expect(editor.textView.string == text + "\n")
        #expect(!cells.isEditing)
        #expect(editor.textView.selectedRange().location == (text as NSString).length + 1)
    }

    @Test func arrowKeysFromTheTextOpenTheCellInTheirColumn() async throws {
        let text = "Lorem ipsum dolor sit amet\n| A | Column B |\n| --- | --- |\n| 1 | 2 |\n\nbelow"
        let (editor, folder, _) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let cells = editor.tableCells!

        // From far right on the line above, ↓ lands in the right-hand column.
        textView.setSelectedRange(NSRange(location: 25, length: 0))
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await waitUntil { cells.isEditing }
        #expect(cells.cellLocation == cell("Column B", in: editor))

        // From the line below, ↑ lands in the last row.
        cells.end(placingCursorAt: (textView.string as NSString).range(of: "below").location)
        textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        try await waitUntil { cells.isEditing }
        #expect([cell("1", in: editor), cell("2", in: editor)].contains(cells.cellLocation ?? -1))
    }

    // MARK: Table commands

    @Test func buttonsAndTheContextMenuChangeTheTableAndKeepEditing() async throws {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\nend"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView
        let cells = editor.tableCells!

        #expect(cells.begin(cellAt: cell("1", in: editor), placing: .end))
        editor.performTableOperation(.addColumnRight)
        #expect(textView.string == "| A | B |  |\n|---|---| --- |\n| 1 |  | 2 |\n\nend"
                || textView.string == "| A |  | B |\n|---| --- |---|\n| 1 |  | 2 |\n\nend"
                || textView.string.contains("|  |"))
        #expect(cells.isEditing)
        textView.undoManager?.undo()
        cells.end(placingCursorAt: nil)
        layOut(textView)

        // The "+" under the last row, while the table is active.
        #expect(cells.begin(cellAt: cell("2", in: editor), placing: .end))
        layOut(textView)
        let lastRow = try #require(row(containing: "| 1 |", in: editor))
        #expect(lastRow.isActive)
        let origin = textView.textContainerOrigin
        var hit: (operation: TableOperation, location: Int)?
        for y in stride(from: origin.y, to: origin.y + 200, by: 2) where hit == nil {
            for x in stride(from: origin.x, to: origin.x + 200, by: 2) {
                if let found = textView.tableButtonHit(at: NSPoint(x: x, y: y)), found.operation == .addRowBelow { hit = found }
            }
        }
        let button = try #require(hit)
        editor.performTableOperation(button.operation, at: button.location)
        #expect(textView.string.contains("| 1 | 2 |\n|  |  |"))

        // Right-click on a cell offers the table's items.
        cells.end(placingCursorAt: nil)
        layOut(textView)
        let frame = try #require(textView.tableCellTextFrame(at: cell("A", in: editor))).frame
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: textView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = try #require(textView.menu(for: event))
        #expect(menu.items.first?.title == "Add Row Above")
    }
}
