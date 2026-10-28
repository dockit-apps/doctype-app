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

    // MARK: Images

    /// A PNG of `width`×`height` pixels (72 dpi), half red and half blue.
    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: width / 2, y: 0, width: width - width / 2, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func image(at location: Int, in textView: NSTextView) -> ImageAttribute? {
        textView.textStorage?.attribute(EditorTheme.imageKey, at: location, effectiveRange: nil) as? ImageAttribute
    }

    @Test func imagesShowUnderTheirLineAtTheirSize() async throws {
        let text = "Intro\n\n![Pic](pic.png)\n\n![Small|120](img/pic.png)\n\n![Gone](missing.png)\n\nend"
        let (editor, folder, window) = try await editor(showing: text, files: ["pic.png": png(width: 800, height: 400)])
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "img"), withIntermediateDirectories: true)
        let textView = editor.textView as! MarkdownTextView
        let string = text as NSString
        let pic = string.range(of: "![Pic](pic.png)")

        // Measured before the note appeared: capped at the default width, aspect kept.
        let attribute = try #require(image(at: pic.location, in: textView))
        #expect(attribute.size == CGSize(width: 400, height: 200))
        #expect(attribute.isSelected == false)
        #expect((textView.textStorage?.attribute(.font, at: pic.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 15 < 1)

        // A missing file keeps its syntax visible and reserves nothing.
        let gone = string.range(of: "![Gone](missing.png)")
        #expect(image(at: gone.location, in: textView) == nil)
        #expect((textView.textStorage?.attribute(.font, at: gone.location, effectiveRange: nil) as? NSFont)?.pointSize == 15)

        // The picture is found where it's drawn, under the line.
        let line = center(of: NSRange(location: pic.location, length: 1), in: textView, window)
        let hit = try #require(textView.imageHit(at: NSPoint(x: textView.textContainerOrigin.x + 30, y: line.y + 120)))
        #expect(hit.range == pic)
        #expect(hit.frame.height == 200)
        #expect(textView.imageHit(at: NSPoint(x: textView.textContainerOrigin.x + 30, y: line.y - 40)) == nil)
    }

    @Test func draggingTheHandleResizesLiveAndWritesTheWidthOnRelease() async throws {
        let text = "![Pic](pic.png)\n\nend"
        let (editor, folder, _) = try await editor(showing: text, files: ["pic.png": png(width: 800, height: 400)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let pic = NSRange(location: 0, length: 15)

        textView.setSelectedRange(NSRange(location: 15, length: 0))  // on the image's line
        #expect(image(at: 0, in: textView)?.isSelected == true)

        editor.resizeImage(at: pic, to: 250, isFinished: false)
        #expect(image(at: 0, in: textView)?.size == CGSize(width: 250, height: 125))
        #expect(textView.string == text)  // nothing written while dragging

        editor.resizeImage(at: pic, to: 250, isFinished: true)
        #expect(textView.string == "![Pic|250](pic.png)\n\nend")
        #expect(image(at: 0, in: textView)?.size == CGSize(width: 250, height: 125))

        textView.undoManager?.undo()
        #expect(textView.string == text)
        // Undo's change notification arrives through the run loop, which tests don't turn.
        editor.styler.applyPendingStyles(in: textView.textStorage!)
        #expect(image(at: 0, in: textView)?.size == CGSize(width: 400, height: 200))
    }

    @Test func anImageTypedLaterAppearsOnceMeasured() async throws {
        let (editor, folder, _) = try await editor(showing: "start\n", files: ["later.png": png(width: 60, height: 30)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        textView.insertText("![x](later.png)", replacementRange: NSRange(location: 6, length: 0))
        textView.insertText("\nmore", replacementRange: textView.selectedRange())  // leave the line

        for _ in 0..<50 where image(at: 6, in: textView) == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(image(at: 6, in: textView)?.size == CGSize(width: 60, height: 30))
    }

    @Test func thumbnailsAreDecodedSmall() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "big.png")
        try png(width: 3000, height: 1500).write(to: url)

        #expect(ImageStore.shared.thumbnail(for: url, maxPixelSize: 512) == nil)  // starts decoding
        var thumbnail: CGImage?
        for _ in 0..<100 where thumbnail == nil {
            try await Task.sleep(for: .milliseconds(20))
            thumbnail = ImageStore.shared.thumbnail(for: url, maxPixelSize: 512)
        }
        #expect(thumbnail?.width == 512)
        #expect(thumbnail?.height == 256)
    }
}
