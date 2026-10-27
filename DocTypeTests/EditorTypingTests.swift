// Drives a real TextKit 2 editor in-process: typing must keep the cursor where
// it belongs, and styles must follow. These catch AppKit/TextKit integration
// bugs that DocTypeCore's tests can't see.

import AppKit
import DocTypeCore
import Foundation
import Testing
@testable import DocType

@MainActor
struct EditorTypingTests {
    /// An editor showing `text` as the open note, from a throwaway library folder.
    private func editor(showing text: String) async throws -> (EditorController, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appending(path: "Note.md"), atomically: true, encoding: .utf8)
        let controller = EditorController()
        controller.library = Library(root: folder)
        #expect(await controller.open("Note.md"))
        return (controller, folder)
    }

    /// Types like a user: insertText at the cursor.
    private func type(_ text: String, in textView: NSTextView) {
        for character in text {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
        }
    }

    private func font(at location: Int, in textView: NSTextView) -> NSFont? {
        textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    @Test func typingInTheMiddleKeepsTheCursorAfterEachCharacter() async throws {
        let (editor, folder) = try await editor(showing: "# Heading\n\nFirst line.\nSecond line.\n\nAnother paragraph.\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 2, length: 0))  // inside "Heading"

        type("abc", in: textView)

        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
        #expect(textView.string.hasPrefix("# abcHeading\n"))
    }

    @Test func stylesFollowTypingAndFences() async throws {
        let (editor, folder) = try await editor(showing: "Intro\n\nBody text.\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("# ", in: textView)
        #expect(font(at: 3, in: textView)?.pointSize == 26)  // "Intro" became a heading

        textView.setSelectedRange(NSRange(location: 9, length: 0))  // start of the blank line's next block
        type("```\n", in: textView)
        #expect(textView.selectedRange().location == 13)
        let bodyLocation = (textView.string as NSString).range(of: "Body").location
        #expect(font(at: bodyLocation, in: textView)?.isFixedPitch == true)  // everything after the fence is code
    }

    @Test func typingInsideACodeBlockKeepsCursorHighlightingAndBox() async throws {
        let (editor, folder) = try await editor(showing: "Intro\n\n```swift\nlet a = 1\n```\n\nAfter.\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let storage = try #require(textView.textStorage)
        let lineEnd = (textView.string as NSString).range(of: "let a = 1").upperBound
        textView.setSelectedRange(NSRange(location: lineEnd, length: 0))

        type("\nvar b = 2", in: textView)

        #expect(textView.selectedRange() == NSRange(location: lineEnd + 10, length: 0))
        let varLocation = (textView.string as NSString).range(of: "var").location
        let keywordColor = storage.attribute(.foregroundColor, at: varLocation, effectiveRange: nil) as? NSColor
        #expect(keywordColor != nil && keywordColor != NSColor.textColor)  // highlighted as a keyword
        #expect(storage.attribute(EditorTheme.codeBlockLineKey, at: varLocation, effectiveRange: nil) != nil)  // inside the box
        #expect(font(at: varLocation, in: textView)?.isFixedPitch == true)
    }

    // MARK: Hidden syntax (shown only on the cursor's line)

    /// Moves the cursor and lets the run loop deliver the selection change,
    /// which TextKit 2 posts a moment later.
    private func moveCursor(to location: Int, in textView: NSTextView) async throws {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        try await Task.sleep(for: .milliseconds(50))
    }

    private func isHidden(at location: Int, in textView: NSTextView) -> Bool {
        (font(at: location, in: textView)?.pointSize ?? 99) < 1
    }

    @Test func headingMarkerShowsOnItsLineAndHidesAfterReturn() async throws {
        let (editor, folder) = try await editor(showing: "")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        type("# Title", in: textView)
        #expect(!isHidden(at: 0, in: textView))  // still on the heading line

        type("\nBody", in: textView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(isHidden(at: 0, in: textView))   // moved away: "#" hidden
        #expect(font(at: 2, in: textView)?.pointSize == 26)  // the title keeps heading size

        try await moveCursor(to: 3, in: textView)  // back onto the heading
        #expect(!isHidden(at: 0, in: textView))
    }

    @Test func typedCodeBlockHidesFencesAfterLeavingIt() async throws {
        let (editor, folder) = try await editor(showing: "")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        type("```swift\nlet a = 1\n```\nAfter", in: textView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(isHidden(at: 0, in: textView))   // "```swift" hidden: cursor is below the block
        let codeLocation = (textView.string as NSString).range(of: "let").location
        #expect(!isHidden(at: codeLocation, in: textView))  // the code itself stays visible

        try await moveCursor(to: codeLocation, in: textView)  // into the block
        #expect(!isHidden(at: 0, in: textView))  // fences and language show again
    }

    @Test func quoteMarkerHidesAndLinesGetTheQuoteBar() async throws {
        let (editor, folder) = try await editor(showing: "> quoted\n\nafter\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let storage = try #require(textView.textStorage)

        try await moveCursor(to: (textView.string as NSString).length, in: textView)

        #expect(isHidden(at: 0, in: textView))
        #expect(storage.attribute(EditorTheme.quoteLineKey, at: 3, effectiveRange: nil) != nil)
    }

    // MARK: Formatting starts only after a space

    private func hasAttribute(_ key: NSAttributedString.Key, at location: Int, in textView: NSTextView) -> Bool {
        textView.textStorage?.attribute(key, at: location, effectiveRange: nil) != nil
    }

    @Test func quoteAppearsOnlyAfterTypingASpace() async throws {
        let (editor, folder) = try await editor(showing: "")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        type(">", in: textView)
        #expect(!hasAttribute(EditorTheme.quoteLineKey, at: 0, in: textView))  // still a plain ">"

        type(" Quoted", in: textView)
        #expect(hasAttribute(EditorTheme.quoteLineKey, at: 0, in: textView))   // "> " made it a quote

        type("\nNext", in: textView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(isHidden(at: 0, in: textView) && isHidden(at: 1, in: textView))  // "> " hidden, space included
    }

    @Test func ruleAppearsAfterASpaceOrWhenLeavingTheLine() async throws {
        let (editor, folder) = try await editor(showing: "Intro\n\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        type("---", in: textView)
        #expect(!hasAttribute(EditorTheme.ruleLineKey, at: 7, in: textView))  // plain dashes while typing

        type(" ", in: textView)
        #expect(hasAttribute(EditorTheme.ruleLineKey, at: 7, in: textView))   // "--- " confirms it

        // Without the space, leaving the line confirms it too.
        textView.setSelectedRange(NSRange(location: 10, length: 1))
        textView.insertText("", replacementRange: textView.selectedRange())  // remove the space again
        #expect(!hasAttribute(EditorTheme.ruleLineKey, at: 7, in: textView))
        type("\nAfter", in: textView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(hasAttribute(EditorTheme.ruleLineKey, at: 7, in: textView))
    }

    @Test func dashUnderTextDoesNotFlashAHeadingWhileTyping() async throws {
        let (editor, folder) = try await editor(showing: "Shopping\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 9, length: 0))

        type("-", in: textView)

        #expect(font(at: 0, in: textView)?.pointSize == 15)  // "Shopping" stays body text
    }

    // MARK: Return and Backspace in quotes

    /// Presses Return or Backspace like the keyboard does (through doCommandBy).
    private func press(_ selector: Selector, in textView: NSTextView) {
        textView.doCommand(by: selector)
    }

    private func lineHeight(at location: Int, in textView: NSTextView) throws -> CGFloat {
        let layout = try #require(textView.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        let textLocation = try #require(layout.location(layout.documentRange.location, offsetBy: location))
        return try #require(layout.textLayoutFragment(for: textLocation)).layoutFragmentFrame.height
    }

    @Test func returnInAQuoteContinuesItVisibly() async throws {
        let (editor, folder) = try await editor(showing: "> test")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        press(#selector(NSResponder.insertNewline(_:)), in: textView)

        #expect(textView.string == "> test\n> ")
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))  // after the hidden "> "
        #expect(hasAttribute(EditorTheme.quoteLineKey, at: 7, in: textView))  // the new line has the bar
        #expect(try lineHeight(at: 7, in: textView) >= 18)                    // and full height, not collapsed
        #expect((textView.typingAttributes[.font] as? NSFont)?.pointSize == 15)  // normal-size cursor and text

        type("more", in: textView)
        #expect(textView.string == "> test\n> more")
        #expect(font(at: 9, in: textView)?.pointSize == 15)
    }

    @Test func secondReturnEndsTheQuote() async throws {
        let (editor, folder) = try await editor(showing: "> test")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        press(#selector(NSResponder.insertNewline(_:)), in: textView)
        press(#selector(NSResponder.insertNewline(_:)), in: textView)
        type("normal", in: textView)

        #expect(textView.string == "> test\n\nnormal")
        let normal = (textView.string as NSString).range(of: "normal").location
        #expect(!hasAttribute(EditorTheme.quoteLineKey, at: normal, in: textView))  // back to a normal paragraph
        #expect(font(at: normal, in: textView)?.pointSize == 15)
    }

    @Test func backspaceAtQuoteStartRemovesTheQuote() async throws {
        let (editor, folder) = try await editor(showing: "> test")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        press(#selector(NSResponder.deleteBackward(_:)), in: textView)

        #expect(textView.string == "test")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func cursorCannotStopInsideTheHiddenPrefix() async throws {
        let (editor, folder) = try await editor(showing: "intro\n> quote")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView

        textView.setSelectedRange(NSRange(location: 6, length: 0))  // start of the quote line, before "> "

        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
    }

    // MARK: Lists and tasks

    @Test func bulletAppearsOnlyAfterTypingASpace() async throws {
        let (editor, folder) = try await editor(showing: "")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        type("-", in: textView)
        #expect(!hasAttribute(EditorTheme.bulletKey, at: 0, in: textView))  // plain "-"

        type(" milk", in: textView)
        #expect(hasAttribute(EditorTheme.bulletKey, at: 0, in: textView))   // drawn as a bullet
    }

    @Test func taskBoxNeedsASpaceAfterTheBrackets() async throws {
        let (editor, folder) = try await editor(showing: "")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        type("- [ ]", in: textView)
        #expect(!hasAttribute(EditorTheme.taskKey, at: 2, in: textView))

        type(" eggs", in: textView)
        #expect(textView.textStorage?.attribute(EditorTheme.taskKey, at: 2, effectiveRange: nil) as? Bool == false)
    }

    @Test func boldMarkersHideWhenLeavingTheLine() async throws {
        let (editor, folder) = try await editor(showing: "")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        type("a **b** c", in: textView)
        #expect(!isHidden(at: 2, in: textView))  // "**" visible on the cursor's line
        #expect(font(at: 4, in: textView).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)

        type("\nnext", in: textView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(isHidden(at: 2, in: textView))
    }

    @Test func returnContinuesANumberedListAndASecondReturnEndsIt() async throws {
        let (editor, folder) = try await editor(showing: "1. one")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        press(#selector(NSResponder.insertNewline(_:)), in: textView)
        type("two", in: textView)
        press(#selector(NSResponder.insertNewline(_:)), in: textView)
        #expect(textView.string == "1. one\n2. two\n3. ")

        press(#selector(NSResponder.insertNewline(_:)), in: textView)
        type("after", in: textView)
        #expect(textView.string == "1. one\n2. two\nafter")
    }

    @Test func returnOnATaskStartsAnUncheckedTask() async throws {
        let (editor, folder) = try await editor(showing: "- [x] done")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 10, length: 0))

        press(#selector(NSResponder.insertNewline(_:)), in: textView)

        #expect(textView.string == "- [x] done\n- [ ] ")
        #expect(textView.selectedRange() == NSRange(location: 17, length: 0))
        #expect(textView.textStorage?.attribute(EditorTheme.taskKey, at: 13, effectiveRange: nil) as? Bool == false)
    }

    @Test func clickingACheckboxTogglesItAndUndoRevertsIt() async throws {
        let (editor, folder) = try await editor(showing: "- [ ] task\n\nafter")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        textView.setSelectedRange(NSRange(location: 17, length: 0))  // cursor on "after"
        try await Task.sleep(for: .milliseconds(50))
        if let layout = textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }

        let boxRect = textView.convert(window.convertFromScreen(
            textView.firstRect(forCharacterRange: NSRange(location: 2, length: 3), actualRange: nil)), from: nil)
        let wordRect = textView.convert(window.convertFromScreen(
            textView.firstRect(forCharacterRange: NSRange(location: 7, length: 3), actualRange: nil)), from: nil)
        #expect(textView.taskBoxLocation(at: NSPoint(x: boxRect.midX, y: boxRect.midY)) == 2)
        #expect(textView.taskBoxLocation(at: NSPoint(x: wordRect.midX, y: wordRect.midY)) == nil)  // the task's text

        editor.toggleTask(at: 2)
        #expect(textView.string == "- [x] task\n\nafter")
        #expect(textView.selectedRange() == NSRange(location: 17, length: 0))  // the cursor didn't move
        #expect(textView.textStorage?.attribute(EditorTheme.taskKey, at: 2, effectiveRange: nil) as? Bool == true)

        textView.undoManager?.undo()
        #expect(textView.string == "- [ ] task\n\nafter")
    }

    @Test func returnThenTabStartsANumberedSubListAtOne() async throws {
        let (editor, folder) = try await editor(showing: "1. one\n2. two")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        press(#selector(NSResponder.insertNewline(_:)), in: textView)
        press(#selector(NSResponder.insertTab(_:)), in: textView)
        type("sub", in: textView)

        #expect(textView.string == "1. one\n   1. sub\n2. two")
    }

    @Test func shiftTabMovesAnItemOutInOneUndoStep() async throws {
        let (editor, folder) = try await editor(showing: "1. one\n   1. sub\n2. two")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView  // the undo manager comes from the window
        textView.setSelectedRange(NSRange(location: 16, length: 0))  // after "sub"

        press(#selector(NSResponder.insertBacktab(_:)), in: textView)
        #expect(textView.string == "1. one\n2. sub\n3. two")
        #expect(textView.selectedRange() == NSRange(location: 13, length: 0))  // still after "sub"

        textView.undoManager?.undo()
        #expect(textView.string == "1. one\n   1. sub\n2. two")
    }

    @Test func tabOnATaskKeepsItACheckbox() async throws {
        let (editor, folder) = try await editor(showing: "- [ ] a\n- [ ] b")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 14, length: 0))

        press(#selector(NSResponder.insertTab(_:)), in: textView)

        #expect(textView.string == "- [ ] a\n  - [ ] b")
        #expect(textView.selectedRange() == NSRange(location: 16, length: 0))
        #expect(textView.textStorage?.attribute(EditorTheme.taskKey, at: 12, effectiveRange: nil) as? Bool == false)
    }

    @Test func tabOutsideAListStillTypesATab() async throws {
        let (editor, folder) = try await editor(showing: "text")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        press(#selector(NSResponder.insertTab(_:)), in: textView)

        #expect(textView.string == "text\t")
    }

    @Test func returnOnAnEmptyNestedItemMovesItUpThenEndsTheList() async throws {
        let (editor, folder) = try await editor(showing: "- groceries\n  - milk")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 20, length: 0))

        press(#selector(NSResponder.insertNewline(_:)), in: textView)  // "  - "
        press(#selector(NSResponder.insertNewline(_:)), in: textView)  // up a level: "- "
        type("eggs", in: textView)
        #expect(textView.string == "- groceries\n  - milk\n- eggs")

        press(#selector(NSResponder.insertNewline(_:)), in: textView)
        press(#selector(NSResponder.insertNewline(_:)), in: textView)  // empty top-level item: list ends
        type("done", in: textView)
        #expect(textView.string == "- groceries\n  - milk\n- eggs\ndone")
    }

    // MARK: Switching notes

    /// Regression: opening a shorter note made TextKit fix the selection mid-swap,
    /// and restyling then used the previous note's block map (NSRangeException
    /// inside a Swift task, which later crashed the app with EXC_BAD_ACCESS).
    @Test func openingAShorterNoteAfterALongOneDoesNotRestyleWithTheOldBlocks() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let long = "# Long\n\n" + String(repeating: "A long first paragraph with **bold** words. ", count: 20) + "\n\n- item\n"
        try long.write(to: folder.appending(path: "Long.md"), atomically: true, encoding: .utf8)
        try "# Short\n\nTiny.\n".write(to: folder.appending(path: "Short.md"), atomically: true, encoding: .utf8)
        let editor = EditorController()
        editor.library = Library(root: folder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView

        #expect(await editor.open("Long.md"))
        editor.textView.setSelectedRange(NSRange(location: (long as NSString).length - 3, length: 0))  // far down
        try await Task.sleep(for: .milliseconds(50))
        #expect(await editor.open("Short.md"))
        try await Task.sleep(for: .milliseconds(50))

        #expect(editor.textView.string == "# Short\n\nTiny.\n")
        #expect(font(at: 3, in: editor.textView)?.pointSize == 26)  // styled for the new note
        #expect(await editor.open("Long.md"))
        #expect(editor.textView.string == long)
    }

    // MARK: Format commands and code fences

    @Test func formatCommandsChangeTheTextInOneUndoStepEach() async throws {
        let (editor, folder) = try await editor(showing: "Title\n\nsome words here")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        editor.format { Formatting.heading(1, in: $0, selection: $1) }
        #expect(textView.string == "# Title\n\nsome words here")
        #expect(font(at: 3, in: textView)?.pointSize == 26)

        textView.undoManager?.undo()  // each command is one undo step (one per event in the app)
        #expect(textView.string == "Title\n\nsome words here")

        textView.setSelectedRange(NSRange(location: 13, length: 0))  // in "words"
        editor.format { Formatting.toggle(.strong, in: $0, selection: $1) }
        #expect(textView.string == "Title\n\nsome **words** here")
        #expect(textView.selectedRange() == NSRange(location: 15, length: 0))
    }

    @Test func returnAfterAnOpeningFenceAddsTheClosingFence() async throws {
        let (editor, folder) = try await editor(showing: "Intro\n\n\n\nAfter")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 7, length: 0))  // the empty line between

        type("```swift", in: textView)
        press(#selector(NSResponder.insertNewline(_:)), in: textView)
        type("let a = 1", in: textView)

        #expect(textView.string == "Intro\n\n```swift\nlet a = 1\n```\n\nAfter")
        let after = (textView.string as NSString).range(of: "After").location
        #expect(font(at: after, in: textView)?.isFixedPitch == false)  // the text below isn't code
    }

    /// Replace All the way NSTextFinder does it: every match replaced in one
    /// editing pass. Must be one undo step and fast in a 5,000-line note.
    @Test func replaceAllInABigNoteIsOneUndoStepAndFast() async throws {
        let line = "Section text with foo and more foo words, a [link](https://x.org) and `code`.\n"
        let (editor, folder) = try await editor(showing: String(repeating: line, count: 5_000))
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        let storage = try #require(textView.textStorage)
        let string = storage.string as NSString
        var matches: [NSValue] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: "foo", range: searchRange)
            guard found.location != NSNotFound else { break }
            matches.append(NSValue(range: found))
            searchRange = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
        }
        #expect(matches.count == 10_000)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            guard textView.shouldChangeText(inRanges: matches, replacementStrings: Array(repeating: "bar", count: matches.count))
            else { return }
            storage.beginEditing()
            for match in matches.reversed() { storage.replaceCharacters(in: match.rangeValue, with: "bar") }
            storage.endEditing()
            textView.didChangeText()
        }
        print("Replace All of 10,000 matches: \(elapsed)")
        #expect(!textView.string.contains("foo"))
        #expect(elapsed < .seconds(1))  // debug build; release is several times faster

        textView.undoManager?.undo()
        #expect(textView.string == String(repeating: line, count: 5_000))
    }

    @Test func findShowsTheFindBar() async throws {
        let (editor, folder) = try await editor(showing: "one two one")
        defer { try? FileManager.default.removeItem(at: folder) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView

        editor.performFind(.showFindInterface)

        #expect(editor.scrollView.isFindBarVisible)
    }
}
