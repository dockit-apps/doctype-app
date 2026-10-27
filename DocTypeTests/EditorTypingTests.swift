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
}

