// Tests for Return, Backspace and cursor movement on list items and tasks,
// and for toggling task boxes.

import Foundation
import Testing
@testable import DocTypeCore

struct ListContinuationTests {
    /// Applies Return at the cursor (marked "|") and returns the result with the new cursor marked.
    private func pressReturn(_ marked: String) -> String? {
        let (text, cursor) = split(marked)
        let string = text as NSString
        guard let edit = ListContinuation.editForNewline(in: string, selection: NSRange(location: cursor, length: 0),
                                                         blockMap: BlockMap(text: string)) else { return nil }
        return mark(edit.applied(to: text), at: edit.selectionAfter.location)
    }

    private func pressBackspace(_ marked: String) -> String? {
        let (text, cursor) = split(marked)
        let string = text as NSString
        guard let edit = ListContinuation.editForBackspace(in: string, selection: NSRange(location: cursor, length: 0),
                                                           blockMap: BlockMap(text: string)) else { return nil }
        return mark(edit.applied(to: text), at: edit.selectionAfter.location)
    }

    /// Where the cursor ends up when moved from `old` to `new` (both marked as offsets).
    private func move(in text: String, from old: Int, to new: Int) -> Int {
        let string = text as NSString
        return ListContinuation.adjustedSelection(
            from: NSRange(location: old, length: 0), to: NSRange(location: new, length: 0),
            in: string, blockMap: BlockMap(text: string)).location
    }

    private func split(_ marked: String) -> (String, Int) {
        let location = (marked as NSString).range(of: "|").location
        return ((marked as NSString).replacingCharacters(in: NSRange(location: location, length: 1), with: ""), location)
    }

    private func mark(_ text: String, at location: Int) -> String {
        (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "|")
    }

    // MARK: Return

    @Test func bulletsContinueWithTheSameBullet() {
        #expect(pressReturn("- one|") == "- one\n- |")
        #expect(pressReturn("* one|") == "* one\n* |")
        #expect(pressReturn("+ one|") == "+ one\n+ |")
        #expect(pressReturn("- one\n- two|\n\nafter") == "- one\n- two\n- |\n\nafter")
    }

    @Test func numbersCountUpAndKeepTheirDelimiter() {
        #expect(pressReturn("1. one|") == "1. one\n2. |")
        #expect(pressReturn("9) nine|") == "9) nine\n10) |")
    }

    @Test func tasksContinueUnchecked() {
        #expect(pressReturn("- [ ] buy milk|") == "- [ ] buy milk\n- [ ] |")
        #expect(pressReturn("- [x] done|") == "- [x] done\n- [ ] |")
        #expect(pressReturn("1. [X] done|") == "1. [X] done\n2. [ ] |")
    }

    @Test func indentationAndQuotesAreKept() {
        #expect(pressReturn("- top\n  - nested|") == "- top\n  - nested\n  - |")
        #expect(pressReturn("\t1. tab|") == "\t1. tab\n\t2. |")
        #expect(pressReturn("> - quoted|") == "> - quoted\n> - |")
        #expect(pressReturn("> > - [ ] deep|") == "> > - [ ] deep\n> > - [ ] |")
    }

    @Test func returnInTheMiddleMovesTheRestIntoTheNewItem() {
        #expect(pressReturn("- buy| milk") == "- buy\n- | milk")
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        #expect(pressReturn("- one\n- |") == "- one\n|")
        #expect(pressReturn("1. one\n2. |") == "1. one\n|")
        #expect(pressReturn("- [ ] one\n- [ ] |") == "- [ ] one\n|")
        #expect(pressReturn("> - one\n> - |") == "> - one\n> |")  // still in the quote; the next Return ends it
        #expect(pressReturn("- one\n-   |") == "- one\n|")  // trailing spaces don't count as text
    }

    @Test func returnOnAnEmptyNestedItemMovesItUpOneLevel() {
        #expect(pressReturn("- groceries\n  - milk\n  - |") == "- groceries\n  - milk\n- |")
        #expect(pressReturn("- [ ] a\n  - [ ] b\n  - [ ] |") == "- [ ] a\n  - [ ] b\n- [ ] |")
        #expect(pressReturn("1. a\n   1. x\n   2. |\n2. b") == "1. a\n   1. x\n2. |\n3. b")  // numbered after its parent
        #expect(pressReturn("> - a\n>   - |") == "> - a\n> - |")
    }

    @Test func eachEmptyReturnClimbsOneLevelUntilTheListEnds() {
        var text = "- a\n  - b\n    - c\n    - |"
        var steps: [String] = []
        while let next = pressReturn(text) {
            steps.append(next)
            text = next
            if steps.count > 5 { break }
        }
        #expect(steps == ["- a\n  - b\n    - c\n  - |", "- a\n  - b\n    - c\n- |", "- a\n  - b\n    - c\n|"])
    }

    @Test func returnBeforeTheItemTextIsNormal() {
        #expect(pressReturn("|- one") == nil)
        #expect(pressReturn("-| one") == nil)
    }

    @Test func notAListMeansNormalReturn() {
        #expect(pressReturn("plain|") == nil)
        #expect(pressReturn("-no space|") == nil)
        #expect(pressReturn("1.no space|") == nil)
        #expect(pressReturn("- - -|") == nil)  // a horizontal rule
        #expect(pressReturn("* * *|") == nil)
        #expect(pressReturn("```\n- code|\n```") == nil)  // a marker inside code is just code
    }

    @Test func followingNumbersAreRenumbered() {
        #expect(pressReturn("1. a|\n2. b\n3. c") == "1. a\n2. |\n3. b\n4. c")
        #expect(pressReturn("1. a|\n2. b\n   nested\n3. c\n\nafter") == "1. a\n2. |\n3. b\n   nested\n4. c\n\nafter")
        #expect(pressReturn("1. a|\n5. b") == "1. a\n2. |\n5. b")  // already in order: untouched
        #expect(pressReturn("1. a|\n2. b\n\n3. c") == "1. a\n2. |\n3. b\n\n3. c")  // a blank line ends it
        #expect(pressReturn("1. a|\n2) b") == "1. a\n2. |\n2) b")  // another list
        #expect(pressReturn("1. a|\n2. b\n   - x") == "1. a\n2. |\n3. b\n   - x")
    }

    // MARK: Backspace and cursor

    @Test func backspaceRightAfterATaskBoxRemovesTheBox() {
        #expect(pressBackspace("- [ ] |task") == "- |task")
        #expect(pressBackspace("- [ ] ta|sk") == nil)
        #expect(pressBackspace("- |item") == nil)  // plain items: normal backspace
    }

    @Test func cursorSkipsATasksHiddenMarker() {
        let text = "intro\n- [ ] task"  // task line starts at 6, its text at 12
        #expect(move(in: text, from: 0, to: 8) == 12)    // clicking into the box
        #expect(move(in: text, from: 12, to: 11) == 5)   // moving left out of the text: previous line
        #expect(move(in: text, from: 5, to: 6) == 6)     // the start of the line is fine
        #expect(move(in: text, from: 13, to: 14) == 14)  // inside the text: untouched
        #expect(move(in: "- item", from: 3, to: 1) == 1) // plain items: untouched
    }

    // MARK: Toggling

    @Test func toggleFlipsTheBox() {
        let selection = NSRange(location: 9, length: 0)
        let check = TaskToggle.edit(togglingBoxAt: 2, in: "- [ ] task", selection: selection)
        #expect(check?.applied(to: "- [ ] task") == "- [x] task")
        #expect(check?.selectionAfter == selection)
        #expect(TaskToggle.edit(togglingBoxAt: 2, in: "- [x] task", selection: selection)?.applied(to: "- [x] task") == "- [ ] task")
        #expect(TaskToggle.edit(togglingBoxAt: 2, in: "- [X] task", selection: selection)?.applied(to: "- [X] task") == "- [ ] task")
        #expect(TaskToggle.edit(togglingBoxAt: 0, in: "- [ ] task", selection: selection) == nil)
        #expect(TaskToggle.edit(togglingBoxAt: 9, in: "- [ ] task", selection: selection) == nil)
    }
}
