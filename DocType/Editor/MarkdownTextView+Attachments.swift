// Dropping and pasting files into the editor. Files (from Finder), file promises
// (Photos, Safari, Mail) and raw image data (a copied screenshot) become
// attachments of the note instead of their path as text; see Library+Attachments.

import AppKit
import UniformTypeIdentifiers

/// Something dropped or pasted that should become an attachment.
enum IncomingAttachment {
    case file(URL)
    /// A file another app wrote to a temporary folder for us; removed once copied.
    case promisedFile(URL)
    case data(Data, name: String)
}

extension MarkdownTextView {
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + [.png, .tiff]
    }

    override func dragOperation(for dragInfo: any NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        Self.hasAttachments(on: dragInfo.draggingPasteboard) ? .copy : super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let location = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty, Self.fileURLs(on: pasteboard).isEmpty {
            receive(promises, at: location)
            return true
        }
        let items = Self.attachments(on: pasteboard)
        guard !items.isEmpty else { return super.performDragOperation(sender) }
        window?.makeFirstResponder(self)
        onAttach(items, location)
        return true
    }

    override func paste(_ sender: Any?) {
        guard !pasteAttachments(from: .general) else { return }
        if let text = NSPasteboard.general.string(forType: .string), onInsertText(text, selectedRange()) { return }
        super.paste(sender)
    }

    /// Attaches files or image data on `pasteboard` at the cursor. False if there
    /// are none, or if there's text too (copied web content pastes as text).
    @discardableResult
    func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        let files = Self.fileURLs(on: pasteboard)
        let items: [IncomingAttachment] = if !files.isEmpty {
            files.map { .file($0) }
        } else if pasteboard.string(forType: .string) == nil, let image = Self.imageData(on: pasteboard) {
            [image]
        } else {
            []
        }
        guard !items.isEmpty else { return false }
        onAttach(items, selectedRange().location)
        return true
    }

    // MARK: - Reading the pasteboard

    static func hasAttachments(on pasteboard: NSPasteboard) -> Bool {
        !fileURLs(on: pasteboard).isEmpty || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self])
            || (pasteboard.string(forType: .string) == nil && imageData(on: pasteboard) != nil)
    }

    private static func attachments(on pasteboard: NSPasteboard) -> [IncomingAttachment] {
        let files = fileURLs(on: pasteboard)
        if !files.isEmpty { return files.map { .file($0) } }
        return imageData(on: pasteboard).map { [$0] } ?? []
    }

    /// Regular files on the pasteboard (folders are left to the default behavior).
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// Image data (PNG, or TIFF converted to PNG) named "Pasted image <date>.png".
    static func imageData(on pasteboard: NSPasteboard) -> IncomingAttachment? {
        let png = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        guard let png else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return .data(png, name: "Pasted image \(formatter.string(from: Date())).png")
    }

    /// Files promised by another app arrive in a temporary folder, then are
    /// attached (copied into the library, and the temporary copy removed).
    private func receive(_ promises: [NSFilePromiseReceiver], at location: Int) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeDrop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, operationQueue: queue) { [weak self] url, error in
                guard error == nil else { return }
                Task { @MainActor in self?.onAttach([.promisedFile(url)], location) }
            }
        }
    }
}
