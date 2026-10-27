// Editing behaviors on top of plain typing: Return and Backspace in quotes, keeping
// the cursor out of hidden syntax, and applying core TextEdits as one undo step.

import AppKit
import DocTypeCore

extension EditorController {
    /// Applies an edit computed by core through NSTextView's undo-aware path, so
    /// one ⌘Z reverts it and styling and autosave follow as for typing.
    func apply(_ edit: TextEdit) {
        guard let storage = textView.textStorage,
              textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.setSelectedRange(edit.selectionAfter)
        textView.didChangeText()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText(), let text = textView.textStorage?.mutableString else { return false }
        let selection = textView.selectedRange()
        let edit: TextEdit? = switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            QuoteEditing.editForNewline(in: text, selection: selection, blockMap: styler.blockMap)
        case #selector(NSResponder.deleteBackward(_:)):
            QuoteEditing.editForBackspace(in: text, selection: selection, blockMap: styler.blockMap)
        default:
            nil
        }
        guard let edit else { return false }
        apply(edit)
        return true
    }

    /// Keeps the cursor out of the hidden "> " of quote lines.
    func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange,
        toCharacterRange newRange: NSRange
    ) -> NSRange {
        guard let text = textView.textStorage?.mutableString else { return newRange }
        return QuoteEditing.adjustedSelection(from: oldRange, to: newRange, in: text, blockMap: styler.blockMap)
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
}
