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
        textView.onInsertText = { [weak self] text, range in self?.insert(text, at: range) ?? false }
        textView.onWillStartComposing = { [weak self] range in self?.makeRoomForComposing(at: range) }
        textView.onComposingEnded = { [weak self] in self?.composingEnded() }
    }

    /// An input method about to compose on the blank line right under a table:
    /// a blank line goes in first, as for typing (its text arrives only when
    /// composing ends, too late to keep it out of the table).
    func makeRoomForComposing(at range: NSRange) {
        guard textView.isEditable, let text = textView.textStorage?.mutableString,
              let edit = TableEditing.editMakingRoomUnderTable(in: text, selection: range, blockMap: styler.blockMap)
        else { return }
        apply(edit)
        roomForComposing = edit.range.location
    }

    /// Composing ended: if nothing was written after all (an accent's dead
    /// key, then Escape), the blank line put in for it goes again.
    func composingEnded() {
        guard let room = roomForComposing else { return }
        roomForComposing = nil
        guard textView.isEditable, let text = textView.textStorage?.mutableString,
              let edit = TableEditing.editTakingBackRoom(at: room, in: text, selection: textView.selectedRange())
        else { return }
        apply(edit)
    }

    /// Text typed or pasted on the blank line right under a table goes on a
    /// line of its own after a blank one (it would join the table as a row,
    /// see TableEditing.editForTyping). False when it goes in as usual.
    func insert(_ typed: String, at range: NSRange) -> Bool {
        guard textView.isEditable, let text = textView.textStorage?.mutableString,
              let edit = TableEditing.editForTyping(typed, in: text, selection: range, blockMap: styler.blockMap)
        else { return false }
        apply(edit)
        return true
    }

    /// Applies `operation` to the table at `location` (default: the cell being
    /// edited, or the cursor), then edits the cell it leads to.
    func performTableOperation(_ operation: TableOperation, at location: Int? = nil) {
        guard let text = textView.textStorage?.mutableString else { return }
        let target = location ?? tableCells.cellLocation ?? textView.selectedRange().location
        let wasEditing = tableCells.isEditing
        tableCells.commit()
        guard let edit = TableEditing.edit(operation, at: target, in: text, blockMap: styler.blockMap,
                                           maximumColumns: EditorTheme.maximumTableColumns) else {
            NSSound.beep()  // e.g. deleting the header row or the last column, or a ninth column
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

    /// Undoes (or redoes) typing in a cell, registered by TableCellSession: puts
    /// `markdown` in `range` and registers the way back. Not NSTextView's own
    /// undo for it: registered while undoing, that one reuses the old range's
    /// length and eats the pipe after the cell. Only the part that differs is
    /// replaced and selected, so the cell then opens with the cursor where the
    /// typing was (it lands in the table, see moveCursorOutOfTables).
    func replaceTableCellText(in range: NSRange, with markdown: String) {
        tableCells.end(placingCursorAt: nil)
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length,
              let undoManager = textView.undoManager else { return }
        let replaced = storage.mutableString.substring(with: range)
        undoManager.disableUndoRegistration()
        apply(TextEdit.replacing(replaced, with: markdown, at: range.location))
        undoManager.enableUndoRegistration()
        let back = NSRange(location: range.location, length: (markdown as NSString).length)
        undoManager.registerUndo(withTarget: self) { $0.replaceTableCellText(in: back, with: replaced) }
        undoManager.setActionName("Typing")
    }

    func isInTable(at location: Int) -> Bool {
        guard let text = textView.textStorage?.mutableString else { return false }
        return TableEditing.table(at: location, in: text, blockMap: styler.blockMap) != nil
    }

    /// Keeps `isInTable` and `canAddTableColumn` (which enable the table
    /// commands) up to date.
    func updateIsInTable() {
        let table = textView.textStorage.flatMap { storage in
            TableEditing.table(at: tableCells.cellLocation ?? textView.selectedRange().location,
                               in: storage.mutableString, blockMap: styler.blockMap)
        }
        let inTable = tableCells.isEditing || table != nil
        if inTable != isInTable { isInTable = inTable }
        let canAdd = (table?.columnCount ?? 0) < EditorTheme.maximumTableColumns
        if canAdd != canAddTableColumn { canAddTableColumn = canAdd }
    }

    /// The note's cursor never stays in a table's hidden markdown: arriving
    /// there (arrow keys, undo, a click beside the cells) edits the cell instead.
    /// A selection reaching out of one cell (select all, a drag) stays as it is,
    /// unless an undo or redo made it (a row that came back): then the cell
    /// where it ends opens.
    func moveCursorOutOfTables() {
        let move = CursorMove(vertical: pendingVerticalMove,
                              isUndo: textView.undoManager.map { $0.isUndoing || $0.isRedoing } ?? false)
        pendingVerticalMove = nil
        guard cellToEdit(after: move) != nil else { return }
        // After this selection change is done (the note's text view is still
        // handling it), worked out again: another change, such as a quick second
        // ⌘Z, may come first.
        DispatchQueue.main.async { [weak self] in
            guard let self, let found = self.cellToEdit(after: move) else { return }
            if found.selection != self.textView.selectedRange() { self.textView.setSelectedRange(found.selection) }
            self.tableCells.begin(cellAt: found.location, placing: found.placement)
        }
    }

    /// How the note's cursor got where it is.
    private struct CursorMove {
        /// ↑ or ↓: where the cursor was across.
        var vertical: (x: CGFloat, up: Bool)?
        var isUndo: Bool
    }

    /// The cell to edit because the note's selection is in a table, where in it
    /// the cursor goes, and the note's selection that leads there; nil when
    /// it isn't, or a cell is open already.
    private func cellToEdit(after move: CursorMove)
        -> (location: Int, placement: TableCellSession.Placement, selection: NSRange)? {
        guard !tableCells.isEditing, !styler.hasPendingEdits, textView.window?.firstResponder === textView,
              let text = textView.textStorage?.mutableString else { return nil }
        var selection = textView.selectedRange()
        guard let table = TableEditing.table(at: selection.location, in: text, blockMap: styler.blockMap) else { return nil }
        // The cell at `location` and its text without the spaces around it.
        func cell(at location: Int) -> (range: NSRange, content: NSRange)? {
            guard let (position, column) = table.position(of: location) else { return nil }
            let row = position == 1 ? 0 : position  // the hidden |---| row: the header
            guard !table.cells[row].isEmpty else { return nil }
            let range = table.cells[row][min(column, table.cells[row].count - 1)]
            return (range, TableEditing.contentRange(of: range, in: text))
        }
        guard var found = cell(at: selection.location) else { return nil }
        var isInCell = selection.location >= found.content.location && NSMaxRange(selection) <= NSMaxRange(found.content)
        if !isInCell, selection.length > 0, move.isUndo, NSMaxRange(selection) <= NSMaxRange(table.range),
           let end = cell(at: NSMaxRange(selection)) {
            selection = NSRange(location: NSMaxRange(selection), length: 0)
            found = end
            isInCell = true
        }
        guard selection.length == 0 || isInCell else { return nil }
        if let vertical = move.vertical, let cellInColumn = textView.tableCell(inRowAt: selection.location, x: vertical.x) {
            // ↑ / ↓ from the text: the cell in the column the cursor was in.
            return (cellInColumn, .line(x: vertical.x, last: vertical.up), selection)
        }
        let content = found.content
        if selection.length > 0 || (selection.location > content.location && selection.location < NSMaxRange(content)) {
            return (found.range.location, .text(selection), selection)
        }
        return (found.range.location, selection.location <= content.location ? .start : .end, selection)
    }
}
