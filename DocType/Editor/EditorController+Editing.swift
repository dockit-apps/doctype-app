// Editing behaviors on top of plain typing: Return, Backspace and Tab in lists and
// quotes, task box clicks, keeping the cursor out of hidden syntax, and applying
// core TextEdits as one undo step.

import AppKit
import DocTypeCore

extension EditorController {
    /// Applies an edit computed by core through NSTextView's undo-aware path, so
    /// one ⌘Z reverts it and styling and autosave follow as for typing.
    func apply(_ edit: TextEdit) {
        guard !edit.isNoChange else {
            textView.setSelectedRange(edit.selectionAfter)  // no undo step for moving the cursor
            return
        }
        guard let storage = textView.textStorage,
              textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.setSelectedRange(edit.selectionAfter)
        textView.didChangeText()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText(), let text = textView.textStorage?.mutableString else { return false }
        let selection = textView.selectedRange()
        let newline = {
            CodeFenceEditing.editForNewline(in: text, selection: selection, blockMap: self.styler.blockMap)
                ?? TableEditing.editForNewline(in: text, selection: selection, blockMap: self.styler.blockMap)
                ?? ListContinuation.editForNewline(in: text, selection: selection, blockMap: self.styler.blockMap)
                ?? QuoteEditing.editForNewline(in: text, selection: selection, blockMap: self.styler.blockMap)
        }
        let edit: TextEdit? = switch selector {
        case #selector(NSResponder.insertNewline(_:)) where NSApp.currentEvent?.modifierFlags.contains(.shift) == true:
            // Shift-Return: a line break inside a table cell; elsewhere a normal Return.
            TableEditing.editForLineBreak(in: text, selection: selection, blockMap: styler.blockMap) ?? newline()
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Option-Return: the same in a cell; elsewhere a plain line break.
            TableEditing.editForLineBreak(in: text, selection: selection, blockMap: styler.blockMap)
        case #selector(NSResponder.insertNewline(_:)):
            newline()
        case #selector(NSResponder.deleteBackward(_:)):
            TableEditing.editForDelete(forward: false, in: text, selection: selection, blockMap: styler.blockMap)
                ?? ListContinuation.editForBackspace(in: text, selection: selection, blockMap: styler.blockMap)
                ?? QuoteEditing.editForBackspace(in: text, selection: selection, blockMap: styler.blockMap)
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            TableEditing.caretForHorizontalMove(forward: selector == #selector(NSResponder.moveRight(_:)), in: text,
                                                selection: selection, blockMap: styler.blockMap)
                .map { TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "",
                                selectionAfter: NSRange(location: $0, length: 0)) }
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            TableEditing.caretForVerticalMove(up: selector == #selector(NSResponder.moveUp(_:)), in: text,
                                              selection: selection, blockMap: styler.blockMap)
                .map { TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "",
                                selectionAfter: NSRange(location: $0, length: 0)) }
        case #selector(NSResponder.deleteForward(_:)):
            TableEditing.editForDelete(forward: true, in: text, selection: selection, blockMap: styler.blockMap)
        case #selector(NSResponder.insertTab(_:)):
            TableEditing.editForTab(forward: true, in: text, selection: selection, blockMap: styler.blockMap)
                ?? ListIndentation.edit(.indent, in: text, selection: selection, blockMap: styler.blockMap)
        case #selector(NSResponder.insertBacktab(_:)):
            TableEditing.editForTab(forward: false, in: text, selection: selection, blockMap: styler.blockMap)
                ?? ListIndentation.edit(.outdent, in: text, selection: selection, blockMap: styler.blockMap)
        default:
            nil
        }
        guard let edit else { return false }
        apply(edit)
        return true
    }

    /// Runs a Format menu transform (core `Formatting`) on the text and selection.
    func format(_ transform: (NSString, NSRange) -> TextEdit) {
        guard let text = textView.textStorage?.mutableString else { return }
        apply(transform(text, textView.selectedRange()))
    }

    /// Shows the find or replace bar, or jumps to the next or previous match.
    func performFind(_ action: NSTextFinder.Action) {
        focusText()
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
    }

    /// Checks or unchecks the task whose box starts at `boxLocation` (one undo step).
    func toggleTask(at boxLocation: Int) {
        guard let text = textView.textStorage?.mutableString,
              let edit = TaskToggle.edit(togglingBoxAt: boxLocation, in: text, selection: textView.selectedRange())
        else { return }
        apply(edit)
    }

    /// Keeps the cursor out of the hidden "> " of quote lines and "- [ ] " of tasks.
    func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange,
        toCharacterRange newRange: NSRange
    ) -> NSRange {
        guard let text = textView.textStorage?.mutableString else { return newRange }
        let outOfQuote = QuoteEditing.adjustedSelection(from: oldRange, to: newRange, in: text, blockMap: styler.blockMap)
        let adjusted = ListContinuation.adjustedSelection(from: oldRange, to: outOfQuote, in: text, blockMap: styler.blockMap)
        return selectionInTableCells(from: oldRange, to: adjusted)
    }

    /// Right after hidden syntax, NSTextView would copy its zero-size font into the
    /// typing attributes (a tiny cursor and tiny letters until restyling). Use the
    /// normal text look instead.
    func textView(
        _ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        guard let font = newTypingAttributes[.font] as? NSFont, font.pointSize < 1 else { return newTypingAttributes }
        var attributes = newTypingAttributes
        let inQuote = attributes[EditorTheme.quoteLineKey] != nil
        attributes[.font] = EditorTheme.bodyFont
        attributes[.foregroundColor] = inQuote ? NSColor.secondaryLabelColor : NSColor.textColor
        return attributes
    }

    /// No spelling marks on what isn't prose: syntax (hidden or dimmed), bare
    /// URLs, image paths and code. Link labels are still checked.
    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0, let storage = textView.textStorage, NSMaxRange(affectedCharRange) <= storage.length else { return value }
        var isProse = true
        storage.enumerateAttributes(in: affectedCharRange) { attributes, run, stop in
            let font = attributes[.font] as? NSFont
            let isSyntax = (font?.pointSize ?? EditorTheme.bodyFont.pointSize) < 1
                || attributes[.foregroundColor] as? NSColor == NSColor.tertiaryLabelColor
            let isCode = font?.isFixedPitch == true
            let isBareURL = (attributes[EditorTheme.linkKey] as? String).map { destination in
                let text = storage.mutableString.substring(with: run)
                return destination.hasSuffix(text) && (text.contains("://") || text.hasPrefix("www."))
            } ?? false
            if isSyntax || isCode || isBareURL || attributes[EditorTheme.imageKey] != nil {
                isProse = false
                stop.pointee = true
            }
        }
        return isProse ? value : 0
    }
}
