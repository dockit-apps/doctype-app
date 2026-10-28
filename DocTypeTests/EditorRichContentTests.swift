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

    /// The x position of every grid line (inside each stretched pipe) in each line of `text`.
    private func pipeColumns(_ text: String, in textView: NSTextView, _ window: NSWindow) -> [[CGFloat]] {
        let string = text as NSString
        var rows: [[CGFloat]] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, _ in
            guard let line, line.contains("|") else { return }
            var xs: [CGFloat] = []
            for offset in 0..<range.length where string.character(at: range.location + offset) == 124 {
                let pipe = range.location + offset
                let rect = textView.firstRect(forCharacterRange: NSRange(location: pipe, length: 1), actualRange: nil)
                let lineOffset = textView.textStorage?.attribute(EditorTheme.tablePipeKey, at: pipe, effectiveRange: nil) as? CGFloat
                xs.append(textView.convert(window.convertFromScreen(rect), from: nil).minX + (lineOffset ?? 0))
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
        // The |---| row is hidden (the cursor isn't on it), so only the visible rows count.
        var rows = pipeColumns(text, in: textView, window)
        #expect(rows.count == 4)
        rows.remove(at: 1)
        for row in rows.dropFirst() {
            for (x, expected) in zip(row, rows[0]) { #expect(abs(x - expected) < 1, "\(rows)") }
        }

        // Typing in a cell re-aligns the whole table.
        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "Bo").upperBound, length: 0))
        textView.insertText("bby Longername", replacementRange: textView.selectedRange())
        editor.styler.applyPendingStyles(in: textView.textStorage!)
        layOut(textView)
        var typed = pipeColumns(textView.string, in: textView, window)
        typed.remove(at: 1)
        for row in typed.dropFirst() {
            for (x, expected) in zip(row, typed[0]) { #expect(abs(x - expected) < 1, "\(typed)") }
        }
    }

    /// The report: a cell's text sat wherever its spaces put it, and in an
    /// empty cell the cursor floated in the middle, away from the typed text.
    @Test func cellTextStartsAtTheSamePlaceAndTheCursorStaysWithIt() async throws {
        let text = "| Column 1 | Column 2 |\n| --- | --- |\n| test | test |\n|test|test|\n|   test|  |"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let string = text as NSString
        func x(_ location: Int) -> CGFloat {
            let rect = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
            return textView.convert(window.convertFromScreen(rect), from: nil).minX
        }
        var tests: [Int] = []
        var search = NSRange(location: 0, length: string.length)
        while case let found = string.range(of: "test", range: search), found.location != NSNotFound {
            tests.append(found.location)
            search = NSRange(location: found.upperBound, length: string.length - found.upperBound)
        }
        #expect(tests.count == 5)
        // Column 1 in every row, however many spaces: the same x.
        let firstColumn = [tests[0], tests[2], tests[4]].map(x)
        #expect(firstColumn.allSatisfy { abs($0 - firstColumn[0]) < 0.5 }, "\(firstColumn)")
        #expect(abs(x(tests[1]) - x(tests[3])) < 0.5)

        // An empty cell: the cursor is at the cell's start, and after typing it
        // sits right after the text.
        let emptyCell = string.length - 2
        textView.setSelectedRange(NSRange(location: emptyCell, length: 0))
        #expect(abs(x(emptyCell) - x(tests[1])) < 0.5)
        textView.insertText("ab", replacementRange: textView.selectedRange())
        editor.styler.applyPendingStyles(in: textView.textStorage!)
        layOut(textView)
        let typed = (textView.string as NSString).range(of: "ab")
        #expect(abs(x(typed.location) - x(tests[1])) < 0.5)
        let glyphEnd = textView.firstRect(forCharacterRange: NSRange(location: typed.location + 1, length: 1), actualRange: nil)
        #expect(abs(x(textView.selectedRange().location) - window.convertFromScreen(glyphEnd).maxX) < 0.5)
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

    // MARK: Table editing

    @Test func tableButtonsAddRowsAndColumnsInOneUndoStepEach() async throws {
        let text = "| A | B |\n|---|---|\n| 1 | 2 |\n\nend"
        let (editor, folder, _) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView

        // Outside the table there are no buttons.
        let origin = textView.textContainerOrigin
        func buttons() -> [(TableOperation, Int)] {
            layOut(textView)
            var found: [(TableOperation, Int)] = []
            for y in stride(from: origin.y, to: origin.y + 160, by: 2) {
                for x in stride(from: origin.x, to: origin.x + 200, by: 2) {
                    if let hit = textView.tableButtonHit(at: NSPoint(x: x, y: y)),
                       !found.contains(where: { $0.0 == hit.operation }) { found.append(hit) }
                }
            }
            return found
        }
        #expect(buttons().isEmpty)

        textView.setSelectedRange(NSRange(location: 2, length: 0))  // in "A"
        #expect(editor.isInTable)
        #expect(buttons().map(\.0) == [.addColumnRight, .addRowBelow])

        let addColumn = try #require(buttons().first { $0.0 == .addColumnRight })
        editor.performTableOperation(addColumn.0, at: addColumn.1)
        #expect(textView.string == "| A | B |  |\n|---|---| --- |\n| 1 | 2 |  |\n\nend")
        textView.undoManager?.undo()
        #expect(textView.string == text)

        let addRow = try #require(buttons().first { $0.0 == .addRowBelow })
        editor.performTableOperation(addRow.0, at: addRow.1)
        #expect(textView.string == "| A | B |\n|---|---|\n| 1 | 2 |\n|  |  |\n\nend")
    }

    /// The report: a table inserted under a task list, filled in with Tab. Its
    /// header must stay the header (not hide as the `|---|` row) and the empty
    /// row must be the one typed into.
    @Test func aTableInsertedUnderAListFillsInWithTab() async throws {
        let (editor, folder, window) = try await editor(showing: "- [ ] test\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView

        editor.insertTable()
        textView.insertText("test", replacementRange: textView.selectedRange())
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        textView.insertText("test2", replacementRange: textView.selectedRange())
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        textView.insertText("x", replacementRange: textView.selectedRange())
        #expect(textView.string == "- [ ] test\n\n| test | test2 |\n| --- | --- |\n| x |  |")

        layOut(textView)
        let string = textView.string as NSString
        func rowHeight(_ piece: String) -> CGFloat {
            textView.firstRect(forCharacterRange: NSRange(location: string.range(of: piece).location, length: 1),
                               actualRange: nil).height
        }
        #expect(rowHeight("test") > 10)
        #expect(rowHeight("x") > 10)
        #expect(rowHeight("---") < 1)  // the hidden |---| row
        _ = window
    }

    /// The report: arrow keys stopped on the hidden `|---|` row, which showed
    /// its dashes, and typing there broke the table.
    @Test func arrowKeysSkipTheHiddenDelimiterRow() async throws {
        let text = "| Name | Grade |\n| --- | --- |\n| Al | 1 |"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView
        let string = text as NSString
        let delimiter = string.range(of: "| --- | --- |")

        textView.setSelectedRange(NSRange(location: string.range(of: "Al").upperBound, length: 0))
        textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(!NSLocationInRange(textView.selectedRange().location, delimiter))
        #expect(textView.selectedRange().location < delimiter.location)  // in the header
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(textView.selectedRange().location > delimiter.upperBound)  // in the body
        textView.setSelectedRange(NSRange(location: string.range(of: "Grade").upperBound, length: 0))
        textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(!NSLocationInRange(textView.selectedRange().location, delimiter))

        // End / Home stop inside the outer pipes, so typing stays in a cell.
        textView.setSelectedRange(NSRange(location: string.range(of: "Al").location + 1, length: 0))
        textView.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
        textView.insertText("0", replacementRange: textView.selectedRange())
        textView.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
        textView.insertText("Dr ", replacementRange: textView.selectedRange())
        #expect(textView.string == "| Name | Grade |\n| --- | --- |\n| Dr Al | 10 |")

        // And it stays collapsed wherever the cursor is.
        layOut(textView)
        let height = textView.firstRect(forCharacterRange: NSRange(location: delimiter.location + 2, length: 1),
                                        actualRange: nil).height
        #expect(height < 1)
        _ = window
    }

    /// The report: ↑ from the first column's first row landed in the second
    /// column's header, and ↓ then switched columns. Also Option-Return, which
    /// put a real line break into the row and broke the table.
    @Test func upAndDownStayInTheirColumnAndLineBreaksStayInTheCell() async throws {
        let text = "| test | Column 2 |\n| --- | --- |\n|  |  |\n| afs |  |\n|  |  |"
        let (editor, folder, _) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView
        let string = text as NSString
        func column() -> Int? {
            TableEditing.table(at: textView.selectedRange().location, in: string, blockMap: editor.styler.blockMap)?
                .position(of: textView.selectedRange().location)?.column
        }

        textView.setSelectedRange(NSRange(location: string.range(of: "|  |  |").location + 2, length: 0))
        textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(textView.selectedRange().location == string.range(of: "test").location)  // first column's header
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(textView.selectedRange().location == string.range(of: "afs").location)
        #expect(column() == 0)

        textView.setSelectedRange(NSRange(location: string.range(of: "Column 2").upperBound, length: 0))
        for _ in 0..<3 {
            textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
            #expect(column() == 1)
        }

        textView.setSelectedRange(NSRange(location: string.range(of: "afs").upperBound, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        textView.insertText("x", replacementRange: textView.selectedRange())
        #expect(textView.string.contains("| afs<br>x |  |\n"))
        #expect(editor.isInTable(at: textView.selectedRange().location))
    }

    /// A table at the very end of a note: its last row's "+" button is below
    /// the text, where TextKit leaves no room of its own.
    @Test func theAddRowButtonWorksAtTheEndOfANote() async throws {
        let text = "| A | B |\n|---|---|\n| 1 | 2 |"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(textView.trailingSpace == EditorTheme.tableRowPadding + EditorTheme.tableButtonSpace)

        layOut(textView)
        let row = center(of: (text as NSString).range(of: "1"), in: textView, window)
        var hit: (operation: TableOperation, location: Int)?
        for y in stride(from: row.y, to: row.y + 60, by: 1) {
            for x in stride(from: textView.textContainerOrigin.x, to: textView.textContainerOrigin.x + 120, by: 2) {
                if let found = textView.tableButtonHit(at: NSPoint(x: x, y: y)) { hit = found }
            }
            if hit != nil { break }
        }
        let button = try #require(hit)
        #expect(button.operation == .addRowBelow)
        editor.performTableOperation(button.operation, at: button.location)
        #expect(textView.string == text + "\n|  |  |")
    }

    @Test func tabAndReturnMoveBetweenCells() async throws {
        let text = "| A | B |\n|---|---|\n| 1 | 2 |"
        let (editor, folder, _) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(textView.selectedRange() == NSRange(location: 6, length: 1))  // "B" selected
        #expect(textView.undoManager?.canUndo != true)  // moving isn't an edit
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(textView.selectedRange() == NSRange(location: 27, length: 0))  // after "2"
        #expect(textView.string == text)
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))  // last cell: adds a row
        #expect(textView.string == text + "\n|  |  |")
    }

    @Test func contextMenuOffersTableItemsOnlyInTables() async throws {
        let text = "| A | B |\n|---|---|\n| 1 | 2 |\n\nplain text"
        let (editor, folder, window) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textView = editor.textView as! MarkdownTextView
        let string = text as NSString

        let inTable = center(of: string.range(of: "1"), in: textView, window)
        let menu = try #require(textView.menu(for: mouse(.rightMouseDown, at: inTable, in: textView)))
        #expect(menu.items.first?.title == "Add Row Above")
        let delete = try #require(menu.items.first { $0.title == "Delete Column" })
        _ = delete.target?.perform(delete.action, with: delete)
        #expect(textView.string == "| B |\n|---|\n| 2 |\n\nplain text")

        layOut(textView)
        let plain = (textView.string as NSString).range(of: "plain")
        #expect(!editor.isInTable(at: plain.location))
        let outside = center(of: plain, in: textView, window)
        #expect(textView.characterIndexForInsertion(at: outside) >= plain.location)
        let plainMenu = textView.menu(for: mouse(.rightMouseDown, at: outside, in: textView))
        #expect(plainMenu?.items.contains { $0.title == "Add Row Above" } != true)
    }
}
