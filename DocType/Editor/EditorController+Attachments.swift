// Turning dropped or pasted files into attachments of the open note: the file
// is copied into the notebook's attachments folder (off the main thread), then
// an image or a link to it is inserted where it was dropped, as one undo step.

import AppKit
import DocTypeCore
import UniformTypeIdentifiers

extension EditorController {
    func attach(_ items: [IncomingAttachment], at location: Int) {
        guard let library, let path else { return }
        Task {
            var links: [(markdown: String, isImage: Bool)] = []
            for item in items {
                do {
                    let relative: String
                    switch item {
                    case .file(let url):
                        relative = try await library.attach(fileAt: url, toNote: path)
                    case .promisedFile(let url):
                        defer { try? FileManager.default.removeItem(at: url) }
                        relative = try await library.attach(fileAt: url, toNote: path)
                    case .data(let data, let name):
                        relative = try await library.attach(data: data, named: name, toNote: path)
                    }
                    let isImage = UTType(filenameExtension: (relative as NSString).pathExtension)?.conforms(to: .image) == true
                    links.append((AttachmentMarkdown.markdown(forPath: relative, isImage: isImage), isImage))
                } catch {
                    onError("Couldn't add the file to “\(path)”: \(error.localizedDescription)")
                }
            }
            // The note may have changed while copying.
            guard self.path == path, !links.isEmpty else { return }
            insertAttachmentLinks(links, at: location)
        }
    }

    /// Images go on lines of their own (they're shown under their line); links to
    /// other files go inline, like any link.
    private func insertAttachmentLinks(_ links: [(markdown: String, isImage: Bool)], at location: Int) {
        let text = textView.string as NSString
        let location = min(max(location, 0), text.length)
        var inserted: String
        if links.contains(where: \.isImage) {
            inserted = links.map(\.markdown).joined(separator: "\n")
            let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
            var lineEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: NSRange(location: location, length: 0))
            if location > lineStart { inserted = "\n" + inserted }
            if location < lineEnd { inserted += "\n" }
        } else {
            inserted = links.map(\.markdown).joined(separator: " ")
        }
        let end = location + (inserted as NSString).length
        apply(TextEdit(range: NSRange(location: location, length: 0), replacement: inserted,
                       selectionAfter: NSRange(location: end, length: 0)))
        textView.window?.makeFirstResponder(textView)
    }
}
