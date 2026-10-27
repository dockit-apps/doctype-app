// Tests for Return, Backspace and cursor movement on quote lines.

import Foundation
import Testing
@testable import DocTypeCore

struct QuoteEditingTests {
    /// Applies Return at `cursor` (marked "|" in `text`) and returns the result with the new cursor marked.
    private func pressReturn(_ marked: String) -> String? {
        let (text, cursor) = split(marked)
        let string = text as NSString
        guard let edit = QuoteEditing.editForNewline(in: string, selection: NSRange(location: cursor, length: 0),
                                                     blockMap: BlockMap(text: string)) else { return nil }
        return mark(edit.applied(to: text), at: edit.selectionAfter.location)
    }

    private func pressBackspace(_ marked: String) -> String? {
        let (text, cursor) = split(marked)
        let string = text as NSString
        guard let edit = QuoteEditing.editForBackspace(in: string, selection: NSRange(location: cursor, length: 0),
                                                       blockMap: BlockMap(text: string)) else { return nil }
        return mark(edit.applied(to: text), at: edit.selectionAfter.location)
    }

    private func split(_ marked: String) -> (String, Int) {
        let location = (marked as NSString).range(of: "|").location
        return ((marked as NSString).replacingCharacters(in: NSRange(location: location, length: 1), with: ""), location)
    }

    private func mark(_ text: String, at location: Int) -> String {
        (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "|")
    }

    @Test func returnContinuesTheQuote() {
        #expect(pressReturn("> test|") == "> test\n> |")
        #expect(pressReturn("> one\n> two|\n\nafter") == "> one\n> two\n> |\n\nafter")
    }

    @Test func returnInTheMiddleSplitsTheLineInsideTheQuote() {
        #expect(pressReturn("> te|st") == "> te\n> |st")
    }

    @Test func nestedQuotesKeepTheirPrefix() {
        #expect(pressReturn("> > deep|") == "> > deep\n> > |")
    }

    @Test func returnOnAnEmptyQuoteLineEndsTheQuote() {
        #expect(pressReturn("> test\n> |") == "> test\n\n|")
        #expect(pressReturn("> test\n>   |") == "> test\n\n|")  // trailing spaces don't count as text
    }

    @Test func returnOutsideQuotesIsNormal() {
        #expect(pressReturn("plain|") == nil)
        #expect(pressReturn(">no space|") == nil)
        #expect(pressReturn("```\n> code|\n```") == nil)  // a quote marker inside code is just code
    }

    @Test func backspaceAtTheStartOfQuoteTextRemovesTheQuote() {
        #expect(pressBackspace("> |test") == "|test")
        #expect(pressBackspace("> te|st") == nil)  // normal backspace elsewhere
        #expect(pressBackspace("plain\n|line") == nil)
    }

    @Test func cursorSkipsTheHiddenPrefix() {
        let text = "intro\n> quote" as NSString
        let map = BlockMap(text: text)
        // Clicking or moving right into "> " lands after it.
        #expect(QuoteEditing.adjustedSelection(from: NSRange(location: 2, length: 0), to: NSRange(location: 6, length: 0),
                                               in: text, blockMap: map) == NSRange(location: 8, length: 0))
        // Moving left from the start of the quote text goes to the end of the line above.
        #expect(QuoteEditing.adjustedSelection(from: NSRange(location: 8, length: 0), to: NSRange(location: 7, length: 0),
                                               in: text, blockMap: map) == NSRange(location: 5, length: 0))
        // Selections and positions in the text are left alone.
        #expect(QuoteEditing.adjustedSelection(from: NSRange(location: 8, length: 0), to: NSRange(location: 6, length: 4),
                                               in: text, blockMap: map) == NSRange(location: 6, length: 4))
        #expect(QuoteEditing.adjustedSelection(from: NSRange(location: 8, length: 0), to: NSRange(location: 10, length: 0),
                                               in: text, blockMap: map) == NSRange(location: 10, length: 0))
    }
}
