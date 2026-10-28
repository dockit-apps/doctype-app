// Walks a library folder once and builds a summary for every `.md` note.
// Hidden folders (.git, .obsidian, …), packages and attachments folders are skipped.

import Foundation

enum LibraryScanner {
    struct Result {
        var notes: [NoteSummary]
        /// Every notebook folder, relative to the root, including empty ones.
        var folders: [String]
    }

    static func scan(root: URL) throws -> Result {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: root])
        }

        var result = Result(notes: [], folders: [])
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = relativePath(of: url, in: root)
            if values.isDirectory == true {
                // A notebook's attachments folder holds files, not notes.
                if url.lastPathComponent.caseInsensitiveCompare(Library.attachmentsFolderName) == .orderedSame {
                    enumerator.skipDescendants()
                    continue
                }
                result.folders.append(path)
            } else if url.pathExtension.lowercased() == "md" {
                result.notes.append(readSummary(at: url, path: path, modified: values.contentModificationDate))
            }
        }
        return result
    }

    static func readSummary(at url: URL, path: String, modified: Date?) -> NoteSummary {
        // A file that isn't UTF-8 is still listed and searchable (NoteText).
        let text = (try? Data(contentsOf: url)).map { NoteText.decode($0).text } ?? ""
        return NoteSummary.make(path: path, text: text, modified: modified ?? .distantPast)
    }

    /// `root/University/Graphs.md` → `University/Graphs.md`.
    static func relativePath(of url: URL, in root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
