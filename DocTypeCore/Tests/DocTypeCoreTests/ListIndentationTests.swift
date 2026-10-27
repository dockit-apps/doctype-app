// Tests for Tab and Shift-Tab on list items: nesting, numbering, and the cursor.

import Foundation
import Testing
@testable import DocTypeCore

struct ListIndentationTests {
    /// Presses Tab or Shift-Tab at the cursor (marked "|"); returns the result with the
    /// new cursor marked, or nil if the key would work as usual.
    private func press(_ direction: ListIndentation.Direction, _ marked: String) -> String? {
        let location = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: location, length: 1), with: "")
        let string = text as NSString
        guard let edit = ListIndentation.edit(direction, in: string, selection: NSRange(location: location, length: 0),
                                              blockMap: BlockMap(text: string)) else { return nil }
        return (edit.applied(to: text) as NSString).replacingCharacters(
            in: NSRange(location: edit.selectionAfter.location, length: 0), with: "|")
    }

    private func tab(_ marked: String) -> String? { press(.indent, marked) }
    private func shiftTab(_ marked: String) -> String? { press(.outdent, marked) }

    // MARK: Tab

    @Test func tabNestsBulletsAndTasksUnderTheItemAbove() {
        #expect(tab("- a\n- b|") == "- a\n  - b|")
        #expect(tab("* a\n* |b") == "* a\n  * |b")  // anywhere in the item's text
        #expect(tab("- [ ] a\n- [ ] b|") == "- [ ] a\n  - [ ] b|")
        #expect(tab("- [x] a\n- [ ] |") == "- [x] a\n  - [ ] |")
    }

    @Test func tabStartsANumberedSubListAtOne() {
        #expect(tab("1. a\n2. b|") == "1. a\n   1. b|")
        #expect(tab("1. a\n2. |") == "1. a\n   1. |")
        #expect(tab("9. a\n10. b|") == "9. a\n   1. b|")
    }

    @Test func numbersBelowCloseTheGap() {
        // Return after "1. a" gave "2. " and made "b" 3.; Tab must give b its 2. back.
        #expect(tab("1. a\n2. |\n3. b") == "1. a\n   1. |\n2. b")
        #expect(tab("1. a\n2. b|\n3. c\n4. d") == "1. a\n   1. b|\n2. c\n3. d")
    }

    @Test func tabJoinsAnExistingSubList() {
        #expect(tab("1. a\n   1. x\n2. b|") == "1. a\n   1. x\n   2. b|")
        #expect(tab("- a\n    - x\n- b|") == "- a\n    - x\n    - b|")  // the sub-list's own indentation wins
    }

    @Test func tabTakesNestedLinesAlong() {
        #expect(tab("- a\n- b|\n  - c\n- d") == "- a\n  - b|\n    - c\n- d")
        #expect(tab("1. a\n2. b|\n   1. x\n3. c") == "1. a\n   1. b|\n      1. x\n2. c")
    }

    @Test func tabWorksInsideQuotesAndWithTabs() {
        #expect(tab("> - a\n> - b|") == "> - a\n>   - b|")
        #expect(tab("\t- a\n\t- b|") == "\t- a\n\t  - b|")
    }

    @Test func tabOnAListsFirstItemChangesNothing() throws {
        let text = "- a" as NSString
        let edit = try #require(ListIndentation.edit(.indent, in: text, selection: NSRange(location: 3, length: 0),
                                                     blockMap: BlockMap(text: text)))
        #expect(edit.isNoChange)
        #expect(tab("- a\n  - b|") == "- a\n  - b|")  // first item of its sub-list
    }

    @Test func tabOutsideListsIsNormal() {
        #expect(tab("plain|") == nil)
        #expect(tab("-no space|") == nil)
        #expect(tab("- - -|") == nil)
        #expect(tab("```\n- a\n- b|\n```") == nil)
    }

    // MARK: Shift-Tab

    @Test func shiftTabMovesAnItemOutAfterItsParent() {
        #expect(shiftTab("- a\n  - b|") == "- a\n- b|")
        #expect(shiftTab("- [ ] a\n  - [ ] b|") == "- [ ] a\n- [ ] b|")
        #expect(shiftTab("1. a\n   1. b|\n2. c") == "1. a\n2. b|\n3. c")
    }

    @Test func shiftTabMakesLaterSiblingsItsChildren() {
        #expect(shiftTab("1. a\n   1. x\n   2. y|\n   3. z\n2. b") == "1. a\n   1. x\n2. y|\n   1. z\n3. b")
    }

    @Test func shiftTabTakesNestedLinesAlong() {
        #expect(shiftTab("- a\n  - b|\n    - c") == "- a\n- b|\n  - c")
    }

    @Test func shiftTabOnATopLevelItemChangesNothing() {
        #expect(shiftTab("- a|") == "- a|")
        #expect(shiftTab("plain|") == nil)
    }

    @Test func tabThenShiftTabRoundTrips() {
        let start = "1. a\n2. b|\n3. c"
        let nested = tab(start)!
        #expect(shiftTab(nested) == start)
    }
}
