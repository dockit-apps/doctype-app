// The text view that edits one table cell, laid over the cell by
// TableCellSession. A real text view, so typing in a cell works as anywhere:
// cursor, selection, input methods, spell checking, copy and paste. It shows
// the cell's text with real line breaks (TableCellText) in the note's font,
// on a clear background over the drawn grid. It has no undo of its own: what's
// typed is a step of the note's undo, and ⌘Z goes to that (the window's).

import AppKit

final class TableCellEditor: NSTextView {
    /// Called when it gains or loses keyboard focus.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Adds the table's items to its context menu.
    var onMenu: (NSMenu) -> Void = { _ in }
    /// A key press is typing or deleting, not a paste, drop or Format command:
    /// key presses in a row are one undo step (TableCellSession).
    private(set) var isTyping = false
    /// The modifier keys of the key press being handled (Shift-Return types a
    /// line break, Return moves down a row); empty outside one. Not
    /// NSApp.currentEvent, which can be a different, older event.
    private(set) var keyModifiers: NSEvent.ModifierFlags = []

    static func make() -> TableCellEditor {
        let editor = TableCellEditor(usingTextLayoutManager: true)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = false  // the note's undo: NSWindow sends ⌘Z there
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

    override func keyDown(with event: NSEvent) {
        let previous = keyModifiers
        keyModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { keyModifiers = previous }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        whileTyping { super.insertText(string, replacementRange: replacementRange) }
    }

    /// An input method's text being composed.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        whileTyping { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
    }

    /// Keys like Delete and Shift-Return (and the arrows, which change no text).
    override func doCommand(by selector: Selector) {
        whileTyping { super.doCommand(by: selector) }
    }

    private func whileTyping(_ body: () -> Void) {
        let wasTyping = isTyping
        isTyping = true
        defer { isTyping = wasTyping }
        body()
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

    /// How wide its text is without wrapping: its longest line, as styled now.
    var unwrappedTextWidth: CGFloat {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        return storage.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).width.rounded(.up)
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
