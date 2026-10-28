// Links and images in a real TextKit 2 editor: hit-testing ⌘-clicks, and image
// thumbnails with their resizing. (Tables: EditorTableTests.)

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

    /// Return after an image at the end of a note: the new empty line goes
    /// under the picture, and the picture stays right under its syntax.
    @Test func returnAfterTheLastImageKeepsItUnderItsLine() async throws {
        let text = "Intro\n\n![Pic](pic.png)"
        let (editor, folder, window) = try await editor(showing: text, files: ["pic.png": png(width: 800, height: 400)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView
        let pic = (text as NSString).range(of: "![Pic](pic.png)")
        let line = center(of: NSRange(location: pic.location, length: 1), in: textView, window)
        func imageTop() throws -> CGFloat {
            layOut(textView)
            return try #require(textView.imageHit(at: NSPoint(x: textView.textContainerOrigin.x + 30, y: line.y + 100))).frame.minY
        }
        // Measured with the cursor off the image's line, where its syntax is hidden.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let before = try imageTop()
        #expect(before < line.y + 20)
        // TextKit leaves out the last paragraph's spacing; the editor adds it below.
        #expect(textView.trailingSpace == 200 + 2 * EditorTheme.imageGap)

        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(try imageTop() == before)
        #expect(textView.trailingSpace == 0)  // the empty last line keeps the spacing
        let cursor = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        #expect(textView.convert(window.convertFromScreen(cursor), from: nil).minY > before + 200)
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
        // Up to 10 s: the decode runs in the background alongside the other tests.
        for _ in 0..<500 where thumbnail == nil {
            try await Task.sleep(for: .milliseconds(20))
            thumbnail = ImageStore.shared.thumbnail(for: url, maxPixelSize: 512)
        }
        #expect(thumbnail?.width == 512)
        #expect(thumbnail?.height == 256)
    }

    // MARK: Attachments

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func pastingAScreenshotSavesItIntoTheNotebooksAttachments() async throws {
        let (editor, folder, _) = try await editor(showing: "Before\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DocTypeTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(png(width: 90, height: 60), forType: .png)

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        #expect(textView.pasteAttachments(from: pasteboard))
        try await waitUntil { textView.string.contains("![") }

        let inserted = try #require(textView.string.components(separatedBy: "\n").last)
        #expect(inserted.hasPrefix("![Pasted image "))
        #expect(inserted.contains("](attachments/Pasted%20image%20"))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "attachments").path)
        #expect(files.count == 1 && files[0].hasPrefix("Pasted image ") && files[0].hasSuffix(".png"))
        try await waitUntil { image(at: 7, in: textView) != nil }
        #expect(image(at: 7, in: textView)?.size == CGSize(width: 90, height: 60))
        #expect(textView.undoManager?.canUndo == true)
    }

    @Test func pastedFilesAreCopiedImagesOnTheirOwnLineOthersInline() async throws {
        let (editor, folder, _) = try await editor(showing: "See  here")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView
        let outside = FileManager.default.temporaryDirectory.appending(path: "DocTypeOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try png(width: 40, height: 40).write(to: outside.appending(path: "Graph.png"))
        try Data("%PDF".utf8).write(to: outside.appending(path: "Week 3.pdf"))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DocTypeTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.writeObjects([outside.appending(path: "Week 3.pdf") as NSURL])
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(textView.pasteAttachments(from: pasteboard))
        try await waitUntil { textView.string.contains("pdf") }
        #expect(textView.string == "See [Week 3](attachments/Week%203.pdf) here")

        pasteboard.clearContents()
        pasteboard.writeObjects([outside.appending(path: "Graph.png") as NSURL])
        textView.setSelectedRange(NSRange(location: 3, length: 0))  // in the middle of the line
        #expect(textView.pasteAttachments(from: pasteboard))
        try await waitUntil { textView.string.contains("png") }
        #expect(textView.string == "See\n![Graph](attachments/Graph.png)\n [Week 3](attachments/Week%203.pdf) here")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "attachments/Graph.png").path))

        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        #expect(!textView.pasteAttachments(from: pasteboard))
    }

    // MARK: Resizing with the mouse

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in textView: NSTextView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: textView.window!.windowNumber, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    @Test func draggingTheHandleWithTheMouseResizesLive() async throws {
        let text = "![Pic](pic.png)\n\nend"
        let (editor, folder, _) = try await editor(showing: text, files: ["pic.png": png(width: 800, height: 400)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView
        let origin = textView.textContainerOrigin
        func imageFrame() throws -> CGRect {
            layOut(textView)
            return try #require(textView.imageHit(at: NSPoint(x: origin.x + 50, y: origin.y + 60))).frame
        }

        // A click on the picture selects it (shows the handle).
        let frame = try imageFrame()
        try #require(textView.imageHit(at: NSPoint(x: frame.midX, y: frame.midY)) != nil)
        textView.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: frame.midX, y: frame.midY), in: textView))
        #expect(image(at: 0, in: textView)?.isSelected == true)

        // Drag the corner handle 100 points left, in steps: the image follows.
        // (Never send a press the view would pass to NSTextView: its tracking loop
        // waits for a real mouse-up and would hang the test.)
        layOut(textView)
        let handle = NSPoint(x: frame.maxX, y: frame.maxY)
        try #require(textView.imageHit(at: handle)?.image.isSelected == true)
        textView.mouseDown(with: mouse(.leftMouseDown, at: handle, in: textView))
        for step in 1...4 {
            textView.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: handle.x - CGFloat(step * 25), y: handle.y), in: textView))
            #expect(image(at: 0, in: textView)?.size.width == 400 - CGFloat(step * 25))
        }
        #expect(textView.string == text)
        #expect(try imageFrame().width == 300)  // the layout follows too

        textView.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: handle.x - 100, y: handle.y), in: textView))
        #expect(textView.string == "![Pic|300](pic.png)\n\nend")
        #expect(image(at: 0, in: textView)?.size == CGSize(width: 300, height: 150))
    }

}
