// Table commands in the editor: inserting a table, and row/column operations from
// the Table menu, the palette, a table's "+" buttons and its context menu. Each
// is one undo step (see TableEditing for the rules).

import AppKit
import DocTypeCore

extension EditorController {
    /// Applies `operation` to the table at `location` (default: the cursor).
    func performTableOperation(_ operation: TableOperation, at location: Int? = nil) {
        guard let text = textView.textStorage?.mutableString else { return }
        let target = location ?? textView.selectedRange().location
        guard let edit = TableEditing.edit(operation, at: target, in: text, blockMap: styler.blockMap) else {
            NSSound.beep()  // e.g. deleting the header row or the last column
            return
        }
        apply(edit)
    }

    func insertTable() {
        guard let text = textView.textStorage?.mutableString else { return }
        apply(TableEditing.insertTable(in: text, selection: textView.selectedRange()))
    }

    func isInTable(at location: Int) -> Bool {
        guard let text = textView.textStorage?.mutableString else { return false }
        return TableEditing.table(at: location, in: text, blockMap: styler.blockMap) != nil
    }

    /// Keeps `isInTable` (which enables the table commands) up to date as the cursor moves.
    func updateIsInTable() {
        let inTable = isInTable(at: textView.selectedRange().location)
        if inTable != isInTable { isInTable = inTable }
    }

    func setUpTables() {
        textView.isInTable = { [weak self] in self?.isInTable(at: $0) ?? false }
        textView.onTableOperation = { [weak self] operation, location in
            self?.performTableOperation(operation, at: location)
        }
    }
}
