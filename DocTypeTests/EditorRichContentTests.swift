// Links, tables and images in a real TextKit 2 editor: hit-testing ⌘-clicks,
// column alignment, and image thumbnails with their resizing.

import AppKit
import DocTypeCore
import Foundation
import Testing
@testable import DocType

@MainActor
struct EditorRichContentTests {
    /// An editor in a window (for undo and hit-testing) showing `Note.md` with
    /// `text`, laid out, with the cursor at the end.
    private func editor(showing text: String, files: [String: Data] = [:]) async throws -> (EditorController, URL, NSWindow) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appending(path: "Note.md"), atomically: true, encoding: .utf8)
        for (name, data) in files { try data.write(to: folder.appending(path: name)) }
        let controller = EditorController()
        controller.library = Library(root: folder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.scrollView
        #expect(await controller.open("Note.md"))
        controller.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        layOut(controller.textView)
        return (controller, folder, window)
    }

    private func layOut(_ textView: NSTextView) {
        if let layout = textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
    }

    /// The center of a character range, in text view coordinates.
    private func center(of range: NSRange, in textView: NSTextView, _ window: NSWindow) -> NSPoint {
        let rect = textView.convert(window.convertFromScreen(textView.firstRect(forCharacterRange: range, actualRange: nil)),
                                    from: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: Links

    @Test func linksAreFoundUnderTheMouse() async throws {
        let text = "Read [the docs](Other.md) or https://swift.org now\n\nend"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView
        let string = text as NSString

        #expect(textView.linkDestination(at: center(of: string.range(of: "docs"), in: textView, window)) == "Other.md")
        #expect(textView.linkDestination(at: center(of: string.range(of: "swift"), in: textView, window)) == "https://swift.org")
        #expect(textView.linkDestination(at: center(of: string.range(of: "Read"), in: textView, window)) == nil)
        #expect(textView.linkDestination(at: center(of: string.range(of: "now"), in: textView, window)) == nil)
    }

    // MARK: Tables

    /// The x position of every pipe in each line of `text`.
    private func pipeColumns(_ text: String, in textView: NSTextView, _ window: NSWindow) -> [[CGFloat]] {
        let string = text as NSString
        var rows: [[CGFloat]] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, _ in
            guard let line, line.contains("|") else { return }
            var xs: [CGFloat] = []
            for offset in 0..<range.length where string.character(at: range.location + offset) == 124 {
                // TextKit reports a character's position halfway into the extra space
                // (kerning) of the character before it; the glyph is drawn after all of it.
                let pipe = range.location + offset
                let rect = textView.firstRect(forCharacterRange: NSRange(location: pipe, length: 1), actualRange: nil)
                let kernBefore = pipe > 0 ? textView.textStorage?.attribute(.kern, at: pipe - 1, effectiveRange: nil) as? CGFloat : nil
                xs.append(textView.convert(window.convertFromScreen(rect), from: nil).minX + (kernBefore ?? 0) / 2)
            }
            rows.append(xs)
        }
        return rows
    }

    @Test func tableColumnsLineUpWithoutChangingTheText() async throws {
        let text = "| Name | Grade |\n|---|:--:|\n| Alexandra Wide | 1.3 |\n| Bo | **10.0** |\n\nafter"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView

        #expect(textView.string == text)
        let rows = pipeColumns(text, in: textView, window)
        #expect(rows.count == 4)
        for row in rows.dropFirst() {
            for (x, expected) in zip(row, rows[0]) { #expect(abs(x - expected) < 1, "\(rows)") }
        }

        // Typing in a cell re-aligns the whole table.
        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "Bo").upperBound, length: 0))
        textView.insertText("bby Longername", replacementRange: textView.selectedRange())
        editor.styler.applyPendingStyles(in: textView.textStorage!)
        layOut(textView)
        let typed = pipeColumns(textView.string, in: textView, window)
        for row in typed.dropFirst() {
            for (x, expected) in zip(row, typed[0]) { #expect(abs(x - expected) < 1, "\(typed)") }
        }
    }
}
