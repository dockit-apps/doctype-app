// How Return, Backspace and the cursor behave on quote lines.
//
// The "> " at the start of a quote line is always hidden; the quote bar shows
// instead, and the text lines up under the line above. So:
// - Return on a quote line with text continues the quote on a new "> " line.
// - Return on an empty quote line ends the quote: the line becomes blank (markdown
//   needs a blank line, or the next text would still belong to the quote) and the
//   cursor starts a normal line below.
// - Backspace at the start of a quote line's text removes the quote from that line.
// - The cursor never stops inside the hidden "> ".
//
// Alternatives considered: showing "> " on the cursor's line (like "#") shifts the
// new line's text right of the quote above; exiting with a single Return makes
// multi-line quotes awkward to type.

import Foundation

public enum QuoteEditing {
    /// Length of the quote prefix ("> ", "> > ", up to 3 leading spaces) at the
    /// start of `line`, or nil if the line isn't a quote line. The prefix needs a
    /// space after ">" (a lone ">" stays plain text).
    public static func prefixLength(ofLine line: NSString) -> Int? {
        let match = line.range(of: "^ {0,3}(>[ \\t])+", options: .regularExpression)
        return match.location == NSNotFound ? nil : match.length
    }

    /// What Return should do at `selection`, or nil to insert a plain line break.
    public static func editForNewline(in text: NSString, selection: NSRange, blockMap: BlockMap) -> TextEdit? {
        guard let line = quoteLine(at: selection.location, in: text, blockMap: blockMap),
              selection.location >= line.contentStart else { return nil }
        if line.isEmpty {
            // Second Return: the empty "> " line becomes a blank line, cursor below it.
            return TextEdit(range: line.range, replacement: "\n",
                            selectionAfter: NSRange(location: line.range.location + 1, length: 0))
        }
        let prefix = text.substring(with: NSRange(location: line.range.location, length: line.prefixLength))
        let inserted = "\n" + prefix
        return TextEdit(range: selection, replacement: inserted,
                        selectionAfter: NSRange(location: selection.location + (inserted as NSString).length, length: 0))
    }

    /// What Backspace should do at `selection`, or nil for a normal backspace.
    public static func editForBackspace(in text: NSString, selection: NSRange, blockMap: BlockMap) -> TextEdit? {
        guard selection.length == 0,
              let line = quoteLine(at: selection.location, in: text, blockMap: blockMap),
              selection.location == line.contentStart else { return nil }
        return TextEdit(range: NSRange(location: line.range.location, length: line.prefixLength), replacement: "",
                        selectionAfter: NSRange(location: line.range.location, length: 0))
    }

    /// Keeps a cursor out of the hidden "> ": moving forward (or clicking) into it
    /// lands after it; moving backward out of a line's text goes to the previous line.
    public static func adjustedSelection(
        from old: NSRange, to new: NSRange, in text: NSString, blockMap: BlockMap
    ) -> NSRange {
        guard new.length == 0, let line = quoteLine(at: new.location, in: text, blockMap: blockMap),
              new.location < line.contentStart else { return new }
        let movingBack = old.length == 0 && old.location == line.contentStart && new.location < old.location
        if movingBack, line.range.location > 0 {
            return NSRange(location: line.range.location - 1, length: 0)
        }
        return NSRange(location: line.contentStart, length: 0)
    }

    // MARK: - Helpers

    private struct QuoteLine {
        /// The line without its line break.
        let range: NSRange
        let prefixLength: Int
        var contentStart: Int { range.location + prefixLength }
        let isEmpty: Bool
    }

    private static func quoteLine(at location: Int, in text: NSString, blockMap: BlockMap) -> QuoteLine? {
        guard location <= text.length else { return nil }
        if let block = blockMap.blocks(in: NSRange(location: location, length: 0)).first, case .code = block.kind {
            return nil  // "> " inside a code block is just code
        }
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        let range = NSRange(location: start, length: contentsEnd - start)
        let content = text.substring(with: range) as NSString
        guard let prefix = prefixLength(ofLine: content) else { return nil }
        let rest = content.substring(from: prefix).trimmingCharacters(in: .whitespaces)
        return QuoteLine(range: range, prefixLength: prefix, isEmpty: rest.isEmpty)
    }
}
