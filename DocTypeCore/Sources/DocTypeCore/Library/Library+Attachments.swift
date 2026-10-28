// Files added to a note (dropped or pasted images, PDFs, …) live in an
// `attachments` folder inside the note's notebook, created when the first one
// arrives. Notes link to them with a relative path ("attachments/Graph.png"),
// so the notebook can be moved, synced or opened in another editor and the
// links still work.
//
// Why per notebook: a lecture's notebook carries its own slides and pictures
// (move or share the folder and they come along), without one huge shared folder.
// `attachments` folders aren't notebooks: the scanner leaves them out of the sidebar.
// A file that's already inside the library isn't copied; the note links to it where it is.

import Foundation

extension Library {
    public static let attachmentsFolderName = "attachments"

    /// Copies `file` into the attachments folder of `notePath`'s notebook (keeping
    /// its name, or "name 2" if taken), or links to it if it's already in the
    /// library. Returns the path to use in the note, relative to the note's folder.
    public func attach(fileAt file: URL, toNote notePath: String) throws -> String {
        assertNotOnMainThread()
        let folder = (notePath as NSString).deletingLastPathComponent
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        if filePath.hasPrefix(rootPath) {
            return Self.relativePath(from: folder, to: String(filePath.dropFirst(rootPath.count)))
        }
        let destination = try availableAttachmentPath(for: file.lastPathComponent, in: folder)
        try FileManager.default.copyItem(at: file, to: url(for: destination))
        return Self.relativePath(from: folder, to: destination)
    }

    /// Saves `data` (e.g. a pasted screenshot) as `name` in the attachments folder
    /// of `notePath`'s notebook. Returns the path relative to the note's folder.
    public func attach(data: Data, named name: String, toNote notePath: String) throws -> String {
        assertNotOnMainThread()
        let folder = (notePath as NSString).deletingLastPathComponent
        let destination = try availableAttachmentPath(for: name, in: folder)
        try data.write(to: url(for: destination), options: .atomic)
        return Self.relativePath(from: folder, to: destination)
    }

    /// A free path for `fileName` in `folder`'s attachments folder, which is created if needed.
    private func availableAttachmentPath(for fileName: String, in folder: String) throws -> String {
        let attachments = folder.isEmpty ? Self.attachmentsFolderName : "\(folder)/\(Self.attachmentsFolderName)"
        try FileManager.default.createDirectory(at: url(for: attachments), withIntermediateDirectories: true)
        let cleaned = fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        return FileNaming.availablePath(name: base.isEmpty || base.hasPrefix(".") ? "Attachment" : base,
                                        extension: ext.isEmpty ? nil : ext, in: attachments) { candidate in
            FileManager.default.fileExists(atPath: url(for: candidate).path)
        }
    }

    /// `to` (relative to the library root) as seen from `folder`: "attachments/a.png",
    /// "../Other/b.pdf".
    static func relativePath(from folder: String, to path: String) -> String {
        let from = folder.split(separator: "/"), target = path.split(separator: "/")
        var common = 0
        while common < from.count, common < target.count - 1, from[common] == target[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + target[common...].map(String.init)).joined(separator: "/")
    }
}

/// The markdown that shows or links an attached file.
public enum AttachmentMarkdown {
    /// `![Graph](attachments/Graph.png)` for images, `[Slides](attachments/Slides.pdf)`
    /// for anything else. Spaces and parentheses in the path are percent-encoded,
    /// so the link works in every markdown renderer.
    public static func markdown(forPath path: String, isImage: Bool) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()")
        let destination = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let label = name.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "|", with: "-")
        return "\(isImage ? "!" : "")[\(label)](\(destination))"
    }
}
