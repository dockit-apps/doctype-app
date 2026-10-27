// Tests for the Format menu transforms and the auto-closing code fence.
// Selections are marked in the text: "|" for a cursor, "[" and "]" around a selection.

import Foundation
import Testing
@testable import DocTypeCore

struct FormattingTests {
    /// Splits "a [bc] d" / "a b|c" into plain text and the marked selection.
    private func parse(_ marked: String) -> (String, NSRange) {
        let string = marked as NSString
        let cursor = string.range(of: "|")
        if cursor.location != NSNotFound {
            return (string.replacingCharacters(in: cursor, with: ""), NSRange(location: cursor.location, length: 0))
        }
        let open = string.range(of: "[[").location, close = string.range(of: "]]").location
        let text = string.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        return (text, NSRange(location: open, length: close - open - 2))
    }

    /// Applies `transform` and marks the selection after it the same way.
    private func run(_ marked: String, _ transform: (NSString, NSRange) -> TextEdit) -> String {
        let (text, selection) = parse(marked)
        let edit = transform(text as NSString, selection)
        let result = edit.applied(to: text) as NSString
        let after = edit.selectionAfter
        if after.length == 0 { return result.replacingCharacters(in: after, with: "|") }
        let closed = result.replacingCharacters(in: NSRange(location: NSMaxRange(after), length: 0), with: "]]") as NSString
        return closed.replacingCharacters(in: NSRange(location: after.location, length: 0), with: "[[")
    }

    private func bold(_ marked: String) -> String { run(marked) { Formatting.toggle(.strong, in: $0, selection: $1) } }
    private func italic(_ marked: String) -> String { run(marked) { Formatting.toggle(.emphasis, in: $0, selection: $1) } }
    private func code(_ marked: String) -> String { run(marked) { Formatting.toggle(.code, in: $0, selection: $1) } }

    // MARK: Bold, italic, code

    @Test func wrapsTheSelection() {
        #expect(bold("a [[big]] dog") == "a **[[big]]** dog")
        #expect(italic("a [[big]] dog") == "a *[[big]]* dog")
        #expect(code("call [[f()]] now") == "call `[[f()]]` now")
    }

    @Test func wrapsTheWordAtTheCursor() {
        #expect(bold("a bi|g dog") == "a **bi|g** dog")
        #expect(bold("a big| dog") == "a **big|** dog")
        #expect(code("use snake_ca|se here") == "use `snake_ca|se` here")
    }

    @Test func unwrapsWhenAlreadyStyled() {
        #expect(bold("a **[[big]]** dog") == "a [[big]] dog")
        #expect(bold("a **bi|g** dog") == "a bi|g dog")
        #expect(bold("a [[**big**]] dog") == "a [[big]] dog")  // markers selected too
        #expect(italic("a *bi|g* dog") == "a bi|g dog")
        #expect(code("call `[[f()]]` now") == "call [[f()]] now")
    }

    @Test func boldAndItalicCombine() {
        #expect(italic("a **bi|g** dog") == "a ***bi|g*** dog")
        #expect(italic("a ***bi|g*** dog") == "a **bi|g** dog")
        #expect(bold("a ***bi|g*** dog") == "a *bi|g* dog")
        #expect(bold("a *bi|g* dog") == "a ***bi|g*** dog")  // bold around italic, not an unwrap
    }

    @Test func emptyPairWhenThereIsNoWord() {
        #expect(bold("a | b") == "a **|** b")
        #expect(bold("a **|** b") == "a | b")  // pressing again removes it
        #expect(code("|") == "`|`")
    }

    // MARK: Link

    @Test func linkWrapsTheSelectionAndWaitsForTheURL() {
        #expect(run("see [[docs]] now") { Formatting.link(in: $0, selection: $1) } == "see [docs](|) now")
        #expect(run("see [[https://swift.org]]") { Formatting.link(in: $0, selection: $1) } == "see [|](https://swift.org)")
        #expect(run("see |") { Formatting.link(in: $0, selection: $1) } == "see [|]()")
    }

    // MARK: Headings

    private func heading(_ level: Int, _ marked: String) -> String {
        run(marked) { Formatting.heading(level, in: $0, selection: $1) }
    }

    @Test func headingSetsChangesAndRemovesTheLevel() {
        #expect(heading(1, "Tit|le") == "# Tit|le")
        #expect(heading(2, "# Tit|le") == "## Tit|le")
        #expect(heading(2, "## Tit|le") == "Tit|le")  // same level again: body text
        #expect(heading(0, "### Tit|le") == "Tit|le")
        #expect(heading(1, "|") == "# |")
        #expect(heading(1, "intro\n|") == "intro\n# |")
    }

    @Test func headingOnSeveralLinesSkipsBlankOnes() {
        #expect(heading(2, "[[one\n\ntwo]]") == "[[## one\n\n## two]]")
        #expect(heading(2, "[[## one\n## two]]") == "[[one\ntwo]]")
        #expect(heading(1, "[[## one\ntwo]]") == "[[# one\n# two]]")  // mixed: all become level 1
    }

    // MARK: Task items

    private func task(_ marked: String) -> String { run(marked) { Formatting.toggleTask(in: $0, selection: $1) } }

    @Test func taskItemAddsABoxKeepingMarkersAndIndentation() {
        #expect(task("buy mi|lk") == "- [ ] buy mi|lk")
        #expect(task("- buy mi|lk") == "- [ ] buy mi|lk")
        #expect(task("1. buy mi|lk") == "1. [ ] buy mi|lk")
        #expect(task("  - nest|ed") == "  - [ ] nest|ed")
        #expect(task("> quo|te") == "> - [ ] quo|te")
        #expect(task("|") == "- [ ] |")
    }

    @Test func taskItemOnTasksRemovesTheBoxes() {
        #expect(task("- [ ] buy mi|lk") == "- buy mi|lk")
        #expect(task("- [x] do|ne") == "- do|ne")
        #expect(task("[[- [ ] a\n- [x] b]]") == "[[- a\n- b]]")
        #expect(task("[[- [ ] a\nb]]") == "[[- [ ] a\n- [ ] b]]")  // mixed: all become tasks
    }

    // MARK: Closing code fences

    private func pressReturn(_ marked: String) -> String? {
        let (text, selection) = parse(marked)
        let string = text as NSString
        guard let edit = CodeFenceEditing.editForNewline(in: string, selection: selection, blockMap: BlockMap(text: string))
        else { return nil }
        return (edit.applied(to: text) as NSString).replacingCharacters(in: edit.selectionAfter, with: "|")
    }

    @Test func returnAfterAnOpeningFenceClosesIt() {
        #expect(pressReturn("```swift|") == "```swift\n|\n```")
        #expect(pressReturn("intro\n\n```|\n\nafter") == "intro\n\n```\n|\n```\n\nafter")
        #expect(pressReturn("~~~~|") == "~~~~\n|\n~~~~")
        #expect(pressReturn("  ```py|") == "  ```py\n  |\n  ```")
    }

    @Test func returnOnAClosedOrNonFenceIsNormal() {
        #expect(pressReturn("```swift|\nlet a = 1\n```") == nil)  // already closed
        #expect(pressReturn("```swift\nlet a = 1\n```|") == nil)  // that's the closing fence
        #expect(pressReturn("```swi|ft") == nil)                   // not at the end of the line
        #expect(pressReturn("``|") == nil)
        #expect(pressReturn("```a`b|") == nil)                     // backticks in the info: inline code
    }
}
