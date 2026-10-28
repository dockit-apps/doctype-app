// How the table cell being edited looks: like the note's own text (bold
// header, inline styles, markers shown only on the cursor's line), and the
// Format commands applied to it. See TableCellSession.

import AppKit
import DocTypeCore

extension TableCellSession {
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
    func restyleEditor() {
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

    /// Runs a Format menu transform on the cell's text (one undo step).
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
}
