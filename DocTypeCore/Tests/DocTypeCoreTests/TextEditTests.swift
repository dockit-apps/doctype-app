// TextEdit's helpers for edits that change only what differs: undoing a table
// cell's typing (`replacing`) and table operations (`minimized`).

import Foundation
import Testing
@testable import DocTypeCore

struct TextEditTests {
    @Test func replacingChangesOnlyTheDifferenceAndSelectsWhatCameIn() {
        // Undoing typing: the typed part goes, the cursor stays where it was typed.
        let undoTyping = TextEdit.replacing("abcXYZ", with: "abc", at: 10)
        #expect(undoTyping == TextEdit(range: NSRange(location: 13, length: 3), replacement: "",
                                       selectionAfter: NSRange(location: 13, length: 0)))
        // Undoing a delete: what came back is selected.
        let undoDelete = TextEdit.replacing("ac", with: "abc", at: 0)
        #expect(undoDelete == TextEdit(range: NSRange(location: 1, length: 0), replacement: "b",
                                       selectionAfter: NSRange(location: 1, length: 1)))
        #expect(TextEdit.replacing("same", with: "same", at: 4).isNoChange)
    }

    @Test func replacingNeverSplitsACharacterAndKeepsItsExactSpelling() {
        // 😀 and 😃 share their first UTF-16 unit: still replaced whole.
        let emoji = TextEdit.replacing("a😀b", with: "a😃b", at: 0)
        #expect(emoji.range == NSRange(location: 1, length: 2))
        #expect(emoji.replacement == "😃")
        // "é" as e + combining accent, and as one scalar: equal as Swift
        // Characters, different text, so it's replaced.
        let decomposed = "caf\u{65}\u{301}", composed = "caf\u{e9}"
        let edit = TextEdit.replacing(decomposed, with: composed, at: 0)
        #expect(edit.applied(to: decomposed).utf16.elementsEqual(composed.utf16))
        #expect(edit.range == NSRange(location: 3, length: 2))
    }

    @Test func replacingGivesTheNewTextForAnyPair() {
        let pairs = [("", "abc"), ("abc", ""), ("aaa", "aaaa"), ("aaaa", "aa"), ("one<br>two", "one two"),
                     ("x | y", "x \\| y"), ("ab", "ba"), ("Özet 🎓", "Özet 🎓 notes")]
        for (old, new) in pairs {
            let text = "<<" + old + ">>"
            let edit = TextEdit.replacing(old, with: new, at: 2)
            #expect(edit.applied(to: text) == "<<" + new + ">>", "\(old) → \(new)")
        }
    }

    @Test func minimizedKeepsTheResultAndTheSelection() {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\nafter" as NSString
        let table = NSRange(location: 0, length: text.range(of: "\n\nafter").location)
        let added = "| A | B |\n| --- | --- |\n| 1 | 2 |\n|  |  |"
        let whole = TextEdit(range: table, replacement: added, selectionAfter: NSRange(location: 36, length: 0))
        let minimal = whole.minimized(in: text)
        #expect(minimal.applied(to: text as String) == whole.applied(to: text as String))
        #expect(minimal.range == NSRange(location: table.upperBound, length: 0))  // just the new row
        #expect(minimal.replacement == "\n|  |  |")
        #expect(minimal.selectionAfter == whole.selectionAfter)
    }
}
