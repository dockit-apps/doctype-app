// Keys that leave the table cell being edited: arrows at its edges, Tab and
// Shift-Tab, Return (which adds a row at the end) and Escape. Core
// TableEditing.target decides where each goes. See TableCellSession.

import AppKit
import DocTypeCore

extension TableCellSession {
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === editor, cell != nil, !editor.hasMarkedText() else { return false }
        let selection = editor.selectedRange()
        let isCursor = selection.length == 0
        let length = (editor.string as NSString).length
        switch selector {
        case #selector(NSResponder.moveLeft(_:)) where isCursor && selection.location == 0:
            return move(.left)
        case #selector(NSResponder.moveRight(_:)) where isCursor && selection.location == length:
            return move(.right)
        case #selector(NSResponder.moveUp(_:)) where isCursor && editor.isCaretOnFirstLine:
            return move(.up)
        case #selector(NSResponder.moveDown(_:)) where isCursor && editor.isCaretOnLastLine:
            return move(.down)
        case #selector(NSResponder.insertTab(_:)):
            return move(.tab)
        case #selector(NSResponder.insertBacktab(_:)):
            return move(.backtab)
        case #selector(NSResponder.insertNewline(_:)) where !editor.keyModifiers.contains(.shift):
            return move(.newline)
        case #selector(NSResponder.cancelOperation(_:)):
            return move(.down, leavingTable: true)
        default:
            return false  // Shift-Return and Option-Return type a line break
        }
    }

    /// Goes where `key` leads from the cell being edited.
    @discardableResult
    func move(_ key: TableEditing.CellKey, leavingTable: Bool = false) -> Bool {
        guard let cell, let storage = textView.textStorage else { return false }
        let text = storage.mutableString
        guard let table = TableEditing.table(at: cell.location, in: text, blockMap: owner.styler.blockMap),
              let (row, column) = table.position(of: cell.location) else { return false }
        if leavingTable {
            leave(table, above: false)
            return true
        }
        let caretX = textView.convert(NSPoint(x: editor.caretRect.midX, y: 0), from: editor).x
        switch TableEditing.target(of: key, fromRow: row, column: column, in: table, text: text) {
        case .cell(let targetRow, let targetColumn):
            let placement: Placement = switch key {
            case .left, .newline: .end
            case .right: .start
            case .up: .line(x: caretX, last: true)
            case .down: .line(x: caretX, last: false)
            case .tab, .backtab: .all
            }
            // A row always has cells (cmark-gfm ends a table at a line that's just "|"), but a
            // wrong index here would crash the app: stay in this cell instead.
            guard table.cells[targetRow].indices.contains(targetColumn) else { return true }
            begin(cellAt: table.cells[targetRow][targetColumn].location, placing: placement)
        case .leaveAbove:
            leave(table, above: true)
        case .leaveBelow:
            leave(table, above: false)
        case .addRow(let targetColumn):
            commit()
            let lastRow = table.cells.count - 1
            let anchor = table.cells[lastRow][min(targetColumn, table.cells[lastRow].count - 1)].location
            guard let edit = TableEditing.edit(.addRowBelow, at: anchor, in: text, blockMap: owner.styler.blockMap) else {
                return true
            }
            owner.apply(edit)
            begin(cellAt: edit.selectionAfter.location, placing: .start)
        case .removeLastRowAndLeave:
            let edit = TableEditing.editRemovingLastRow(of: table, in: text)
            end(placingCursorAt: nil)
            owner.apply(edit)
        }
        return true
    }

    /// Out of the table: to the end of the line above it, or below it past a
    /// blank line (TableEditing.editLeavingBelow).
    private func leave(_ table: TableLayout, above: Bool) {
        guard let storage = textView.textStorage else { return }
        let text = storage.mutableString
        if above {
            guard table.range.location > 0 else { return NSSound.beep() }
            var start = 0, end = 0
            text.getLineStart(&start, end: nil, contentsEnd: &end, for: NSRange(location: table.range.location - 1, length: 0))
            self.end(placingCursorAt: end)
            return
        }
        let edit = TableEditing.editLeavingBelow(table, in: text)
        end(placingCursorAt: nil)
        owner.apply(edit)  // only moves the cursor, unless lines are added at the end
    }
}
