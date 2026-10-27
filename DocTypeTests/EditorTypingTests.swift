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
}

