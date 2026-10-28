// Tables in the editor: inserting one, row and column operations (Table menu,
// palette, "+" buttons, context menu), and keeping the note's cursor out of a
// table's hidden markdown: cells are edited in TableCellSession. Each
// operation is one undo step (see TableEditing for the rules).

import AppKit
import DocTypeCore

extension EditorController {
    func setUpTables() {
        textView.onTableOperation = { [weak self] operation, location in
            self?.performTableOperation(operation, at: location)
        }
        textView.onTableCellClick = { [weak self] location, event in
            self?.tableCells.begin(cellAt: location, placing: .click(event))
        }
    }

    /// Applies `operation` to the table at `location` (default: the cell being
    /// edited, or the cursor), then edits the cell it leads to.
    func performTableOperation(_ operation: TableOperation, at location: Int? = nil) {
        guard let text = textView.textStorage?.mutableString else { return }
        let target = location ?? tableCells.cellLocation ?? textView.selectedRange().location
        let wasEditing = tableCells.isEditing
        tableCells.commit()
        guard let edit = TableEditing.edit(operation, at: target, in: text, blockMap: styler.blockMap) else {
            NSSound.beep()  // e.g. deleting the header row or the last column
            if wasEditing { tableCells.begin(cellAt: target, placing: .end) }
            return
        }
        apply(edit)
        tableCells.begin(cellAt: edit.selectionAfter.location, placing: .end)
    }

    /// Inserts a table at the cursor and edits its first header, selected.
    func insertTable() {
        guard let text = textView.textStorage?.mutableString else { return }
        let edit = TableEditing.insertTable(in: text, selection: textView.selectedRange())
        apply(edit)
        tableCells.begin(cellAt: edit.selectionAfter.location, placing: .text(edit.selectionAfter))
    }

    /// Undoes (or redoes) a cell's edit, registered by TableCellSession: puts
    /// `markdown` in `range` and registers the way back. Not NSTextView's own
    /// undo for it: registered while undoing, that one reuses the old range's
    /// length and eats the pipe after the cell. The cell then opens (the cursor
    /// lands in the table, see moveCursorOutOfTables).
    func replaceTableCellText(in range: NSRange, with markdown: String) {
        tableCells.end(placingCursorAt: nil)
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length,
              let undoManager = textView.undoManager else { return }
        let replaced = storage.mutableString.substring(with: range)
        undoManager.disableUndoRegistration()
        apply(TextEdit(range: range, replacement: markdown, selectionAfter: NSRange(location: range.location, length: 0)))
        undoManager.enableUndoRegistration()
        let back = NSRange(location: range.location, length: (markdown as NSString).length)
        undoManager.registerUndo(withTarget: self) { $0.replaceTableCellText(in: back, with: replaced) }
        undoManager.setActionName("Typing")
    }

    func isInTable(at location: Int) -> Bool {
        guard let text = textView.textStorage?.mutableString else { return false }
        return TableEditing.table(at: location, in: text, blockMap: styler.blockMap) != nil
    }

    /// Keeps `isInTable` (which enables the table commands) up to date.
    func updateIsInTable() {
        let inTable = tableCells.isEditing || isInTable(at: textView.selectedRange().location)
        if inTable != isInTable { isInTable = inTable }
    }

    /// The note's cursor never stays in a table's hidden markdown: arriving
    /// there (arrow keys, undo, a click beside the cells) edits the cell instead.
    /// A selection reaching out of one cell (select all, a drag) stays as it is.
    func moveCursorOutOfTables() {
        let vertical = pendingVerticalMove
        pendingVerticalMove = nil
        guard !tableCells.isEditing, !styler.hasPendingEdits, textView.window?.firstResponder === textView,
              let text = textView.textStorage?.mutableString else { return }
        let selection = textView.selectedRange()
        guard let table = TableEditing.table(at: selection.location, in: text, blockMap: styler.blockMap),
              let (position, column) = table.position(of: selection.location) else { return }
        let row = position == 1 ? 0 : position
        guard !table.cells[row].isEmpty else { return }
        let cell = table.cells[row][min(column, table.cells[row].count - 1)]
        let content = TableEditing.contentRange(of: cell, in: text)
        guard selection.length == 0
                || (selection.location >= content.location && NSMaxRange(selection) <= NSMaxRange(content)) else { return }
        var target = cell.location
        let placement: TableCellSession.Placement
        if let vertical, let cellInColumn = textView.tableCell(inRowAt: selection.location, x: vertical.x) {
            // ↑ / ↓ from the text: the cell in the column the cursor was in.
            target = cellInColumn
            placement = .line(x: vertical.x, last: vertical.up)
        } else if selection.length > 0 || (selection.location > content.location && selection.location < NSMaxRange(content)) {
            placement = .text(selection)
        } else {
            placement = selection.location <= content.location ? .start : .end
        }
        // After this selection change is done; the note's text view is still handling it.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.tableCells.isEditing else { return }
            self.tableCells.begin(cellAt: target, placing: placement)
        }
    }
}
