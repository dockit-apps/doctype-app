// The text view that edits one table cell, laid over the cell by
// TableCellSession. A real text view, so typing in a cell works as anywhere:
// cursor, selection, input methods, spell checking, copy and paste. It shows
// the cell's text with real line breaks (TableCellText) in the note's font,
// on a clear background over the drawn grid.

import AppKit

final class TableCellEditor: NSTextView {
    /// Called when it gains or loses keyboard focus.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Adds the table's items to its context menu.
    var onMenu: (NSMenu) -> Void = { _ in }

    static func make() -> TableCellEditor {
        let editor = TableCellEditor(usingTextLayoutManager: true)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        // Like the note: markdown needs literal characters.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = true
        editor.font = EditorTheme.bodyFont
        editor.textColor = .textColor
        editor.typingAttributes = EditorTheme.baseAttributes
        editor.isHidden = true
        return editor
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange(false) }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // A copy: NSTextView hands out one shared menu, which must not keep our items.
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        onMenu(menu)
        return menu
    }

    /// The height its text needs at its current width (at least one line).
    var textHeight: CGFloat {
        guard let layout = textLayoutManager else { return EditorTheme.emptyCellHeight }
        layout.ensureLayout(for: layout.documentRange)
        return max(layout.usageBoundsForTextContainer.height.rounded(.up), EditorTheme.emptyCellHeight)
    }

    /// Where the cursor is drawn, in this view's coordinates.
    var caretRect: CGRect {
        guard let window else { return .zero }
        let onScreen = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
        return convert(window.convertFromScreen(onScreen), from: nil)
    }

    /// The cursor is on the text's first (or last) line as laid out, wrapped lines counted.
    var isCaretOnFirstLine: Bool { abs(caretRect.minY - lineRect(at: 0).minY) < 1 }
    var isCaretOnLastLine: Bool { abs(caretRect.minY - lineRect(at: (string as NSString).length).minY) < 1 }

    private func lineRect(at location: Int) -> CGRect {
        guard let window else { return .zero }
        let onScreen = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        return convert(window.convertFromScreen(onScreen), from: nil)
    }
}
