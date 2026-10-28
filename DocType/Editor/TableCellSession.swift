// Editing a table one cell at a time, the way Obsidian does: a real text view
// (TableCellEditor) is laid over the cell, everything typed there goes straight
// into the note's markdown (`<br>` for a line break, `\|` for "|"), the row
// grows and shrinks with the text, and keys at a cell's edge move to the next
// cell (TableEditing.target).
//
// Undo: while in a cell, ⌘Z undoes typing in it step by step (the editor's own
// undo manager); once you leave the cell, its whole edit is one step of the
// note's undo. The note's text is changed without undo while you type.
// The note's own text view never keeps its cursor in a table: arriving there
// (arrow keys, a click, undo) opens the cell instead (see EditorController+Tables).

import AppKit
import DocTypeCore

final class TableCellSession: NSObject, NSTextViewDelegate {
    let editor = TableCellEditor.make()
    private let cellUndoManager = UndoManager()
    private unowned let owner: EditorController

    /// The cell being edited.
    private struct EditingCell {
        /// Where the cell starts in the note (just after its opening pipe). It
        /// stays put while its text changes.
        let location: Int
        /// The cell's text in the note now, without the spaces around it.
        var contentRange: NSRange
        var text: TableCellText
        /// Its markdown when editing began, for the note's undo.
        let originalMarkdown: String
        let isHeader: Bool
        let alignment: TableAlignment
    }
    private var cell: EditingCell?

    var isEditing: Bool { cell != nil }
    /// Where the cell being edited starts in the note.
    var cellLocation: Int? { cell?.location }

    /// Where the cursor goes when a cell is opened.
    enum Placement {
        case start, end, all
        /// A range of the note's text (it's in the cell).
        case text(NSRange)
        /// On the cell's first or last line, at `x` (the note's coordinates).
        case line(x: CGFloat, last: Bool)
        /// Where a click lands: the editor handles the mouse from here (drag to select, double-click).
        case click(NSEvent)
    }

    init(owner: EditorController) {
        self.owner = owner
        super.init()
        editor.delegate = self
        editor.onFocusChange = { [weak self] focused in self?.focusChanged(focused) }
        editor.onMenu = { [weak self] menu in
            guard let self, let location = self.cell?.location else { return }
            self.owner.textView.addTableItems(to: menu, location: location)
        }
    }

    private var textView: MarkdownTextView { owner.textView }

    // MARK: - Opening and closing a cell

    /// Starts editing the cell containing `location` (finishing the one being
    /// edited, as one undo step). Returns false outside a table.
    @discardableResult
    func begin(cellAt location: Int, placing placement: Placement) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let text = storage.mutableString
        guard let table = TableEditing.table(at: location, in: text, blockMap: owner.styler.blockMap),
              let (position, columnAt) = table.position(of: location) else { return false }
        let row = position == 1 ? 0 : position  // the hidden |---| row: the header
        guard !table.cells[row].isEmpty else { return false }
        // Past a short row's last cell: that cell.
        let column = min(columnAt, table.cells[row].count - 1)
        let cellRange = table.cells[row][column]
        if cell?.location == cellRange.location {
            place(placement)  // the same cell (a click on its padding): just move the cursor
            return true
        }
        commit()
        let content = TableEditing.contentRange(of: cellRange, in: text)
        let markdown = text.substring(with: content)
        let cellText = TableCellText(markdown: markdown)
        cell = EditingCell(location: cellRange.location, contentRange: content, text: cellText, originalMarkdown: markdown,
                           isHeader: row == 0, alignment: TableEditing.alignment(ofColumn: column, in: table, text: text))
        editor.string = cellText.editorText
        cellUndoManager.removeAllActions()
        restyleEditor()
        if editor.superview !== textView { textView.addSubview(editor) }
        editor.isHidden = false
        placeEditor()
        textView.window?.makeFirstResponder(editor)
        place(placement)
        owner.isEditingTableCell = true
        owner.updateIsInTable()
        return true
    }

    /// Finishes the cell being edited (its edit becomes one undo step of the
    /// note) and leaves the editor where it is, for another cell.
    func commit() {
        guard let cell else { return }
        self.cell = nil
        owner.styler.editingTableCell = nil
        let final = cell.text.markdown
        if final != cell.originalMarkdown {
            let range = NSRange(location: cell.contentRange.location, length: (final as NSString).length)
            let original = cell.originalMarkdown
            textView.undoManager?.registerUndo(withTarget: owner) { owner in
                owner.replaceTableCellText(in: range, with: original)
            }
            textView.undoManager?.setActionName("Typing")
        }
    }

    /// Stops editing: finishes the cell, hides the editor and gives the note the
    /// keyboard, its cursor at `location` (nil: where it was).
    func end(placingCursorAt location: Int?) {
        guard let cellLocation = cell?.location else { return }
        commit()
        if let location { textView.setSelectedRange(NSRange(location: location, length: 0)) }
        // Before hiding the editor: a hidden first responder hands the keyboard to the window.
        textView.window?.makeFirstResponder(textView)
        hideEditor(restylingAt: cellLocation)
    }

    /// Drops the cell without an undo step (the note's text is being replaced).
    func cancel() {
        guard cell != nil else { return }
        cell = nil
        owner.styler.editingTableCell = nil
        if textView.window?.firstResponder === editor { textView.window?.makeFirstResponder(textView) }
        editor.isHidden = true
        owner.isEditingTableCell = false
    }

    private func hideEditor(restylingAt location: Int) {
        editor.isHidden = true
        owner.isEditingTableCell = false
        if let storage = textView.textStorage, location <= storage.length {
            owner.styler.restyle([NSRange(location: location, length: 0)], in: storage)
        }
        owner.updateIsInTable()
    }

    /// Clicking elsewhere ends the cell.
    private func focusChanged(_ focused: Bool) {
        owner.cellEditorFocusChanged(focused)
        guard !focused, let location = cell?.location else { return }
        commit()
        hideEditor(restylingAt: location)
    }

    // MARK: - Layout

    /// Lays the editor over its cell, as wide as the column, and makes the row
    /// as tall as the editor's text needs. Call after the note's text or the
    /// editor's width changed.
    func placeEditor() {
        guard let cell, let storage = textView.textStorage else { return }
        // The column's width decides how the text wraps, so how tall the row must
        // be; the row's height never changes the width again.
        for _ in 0..<3 {
            guard let (frame, _) = textView.tableCellTextFrame(at: cell.location) else { return }
            editor.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(editor.frame.height, 1))
            let needed = editor.textHeight
            editor.frame.size.height = needed
            if let editing = owner.styler.editingTableCell, editing.location == cell.location, editing.height == needed { return }
            owner.styler.editingTableCell = (cell.location, needed)
            owner.styler.restyle([NSRange(location: cell.location, length: 0)], in: storage)
        }
    }

    /// Puts the cursor in the opened cell.
    private func place(_ placement: Placement) {
        let length = (editor.string as NSString).length
        switch placement {
        case .start:
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        case .end:
            editor.setSelectedRange(NSRange(location: length, length: 0))
        case .all:
            editor.setSelectedRange(NSRange(location: 0, length: length))
        case .text(let range):
            guard let cell else { return }
            let relative = NSRange(location: range.location - cell.contentRange.location, length: range.length)
            editor.setSelectedRange(cell.text.editorRange(forMarkdownRange: relative))
        case .line(let x, let last):
            let inEditor = editor.convert(NSPoint(x: x, y: 0), from: textView)
            let y = last ? editor.bounds.maxY - 2 : 2
            editor.setSelectedRange(NSRange(location: editor.characterIndexForInsertion(at: NSPoint(x: inEditor.x, y: y)),
                                            length: 0))
        case .click(let event):
            editor.mouseDown(with: event)
        }
    }

    // MARK: - Typing

    /// Everything typed goes straight into the note, without the note's undo.
    func textDidChange(_ notification: Notification) {
        guard var cell, let storage = textView.textStorage else { return }
        let markdown = TableCellText.markdown(fromEditorText: editor.string)
        cell.text = TableCellText(markdown: markdown)
        let current = storage.mutableString.substring(with: cell.contentRange)
        if markdown != current {
            owner.styler.editingTableCell = (cell.location, editor.textHeight)
            let undo = textView.undoManager
            undo?.disableUndoRegistration()
            if textView.shouldChangeText(in: cell.contentRange, replacementString: markdown) {
                storage.replaceCharacters(in: cell.contentRange, with: markdown)
                cell.contentRange.length = (markdown as NSString).length
                self.cell = cell
                textView.didChangeText()  // restyles the table and saves, like typing in the note
            }
            undo?.enableUndoRegistration()
        }
        self.cell = cell
        restyleEditor()
        placeEditor()
    }

    /// The editor's own undo, so ⌘Z in a cell undoes typing in it.
    func undoManager(for view: NSTextView) -> UndoManager? { cellUndoManager }

    func textViewDidChangeSelection(_ notification: Notification) {
        restyleEditor()  // markdown markers show on the cursor's line
    }

    /// Next to hidden markers, NSTextView would copy their zero-size font into
    /// the typing attributes; use the cell's look instead.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        guard let font = newTypingAttributes[.font] as? NSFont, font.pointSize < 1 else { return newTypingAttributes }
        return typingAttributes
    }

    private var typingAttributes: [NSAttributedString.Key: Any] {
        var attributes = EditorTheme.baseAttributes
        attributes[.paragraphStyle] = EditorTheme.cellParagraphStyle(cell?.alignment ?? .left)
        if cell?.isHeader == true {
            attributes[.font] = NSFontManager.shared.convert(EditorTheme.bodyFont, toHaveTrait: .boldFontMask)
        }
        return attributes
    }

    /// Styles the cell's text like the note: as GitHub would show it in this
    /// cell (bold header, inline styles), with markdown markers dimmed on the
    /// cursor's line and hidden elsewhere.
    private func restyleEditor() {
        guard let cell, !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        let markdown = cell.text.markdown as NSString
        // The cell inside a table of its own, so it's parsed as a cell, nothing else.
        let prefix = cell.isHeader ? "| " : "| x |\n| --- |\n| "
        let suffix = cell.isHeader ? " |\n| --- |" : " |"
        let table = (prefix + (markdown as String) + suffix) as NSString
        let offset = (prefix as NSString).length
        let inTable = NSRange(location: offset, length: markdown.length)
        let shown = editor.string as NSString
        var spans: [StyleSpan] = []
        for span in MarkdownStyler.spans(in: table, blocks: BlockMap(text: table).blocks) {
            switch span.style {
            case .strong, .emphasis, .strikethrough, .inlineCode, .link, .syntaxMarker: break
            default: continue
            }
            let clipped = NSIntersectionRange(span.range, inTable)
            guard clipped.length > 0 else { continue }
            let range = cell.text.editorRange(forMarkdownRange: NSRange(location: clipped.location - offset, length: clipped.length))
            guard range.length > 0, NSMaxRange(range) <= shown.length else { continue }
            var reveal: NSRange?
            if span.style == .syntaxMarker {
                var start = 0, end = 0
                shown.getLineStart(&start, end: nil, contentsEnd: &end, for: NSRange(location: range.location, length: 0))
                reveal = NSRange(location: start, length: end - start)
            }
            spans.append(StyleSpan(range, span.style, revealRange: reveal))
        }
        let whole = NSRange(location: 0, length: shown.length)
        let restyle = {
            storage.beginEditing()
            EditorTheme.apply(spans, to: storage, resetting: whole, selection: self.editor.selectedRange())
            storage.addAttribute(.paragraphStyle, value: EditorTheme.cellParagraphStyle(cell.alignment), range: whole)
            storage.endEditing()
        }
        if let content = editor.textContentStorage { content.performEditingTransaction(restyle) } else { restyle() }
        editor.typingAttributes = typingAttributes
    }

    /// Runs a Format menu transform on the cell's text (one step of its undo).
    func format(_ transform: (NSString, NSRange) -> TextEdit) {
        guard let storage = editor.textStorage else { return }
        let edit = transform(storage.mutableString, editor.selectedRange())
        guard !edit.isNoChange else {
            editor.setSelectedRange(edit.selectionAfter)
            return
        }
        guard editor.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        editor.setSelectedRange(edit.selectionAfter)
        editor.didChangeText()
    }

    // MARK: - Moving between cells

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
        case #selector(NSResponder.insertNewline(_:)) where NSApp.currentEvent?.modifierFlags.contains(.shift) != true:
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

    /// Out of the table: to the end of the line above it, or the start of the
    /// line below it (a new one when the table ends the note).
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
        var lineEnd = 0
        text.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: NSRange(location: NSMaxRange(table.range), length: 0))
        if lineEnd > NSMaxRange(table.range) {
            end(placingCursorAt: lineEnd)
        } else {
            end(placingCursorAt: nil)
            owner.apply(TextEdit(range: NSRange(location: text.length, length: 0), replacement: "\n",
                                 selectionAfter: NSRange(location: text.length + 1, length: 0)))
        }
    }
}
