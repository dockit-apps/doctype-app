// What ⌘-clicking a link opens.
//
// - Anything with a scheme (`https:`, `mailto:`, `file:`, …) opens with the
//   system, like clicking it in Mail.
// - A path is relative to the note's folder (`../Uni/Graphs.md`, `img/a.pdf`),
//   as on GitHub and in Obsidian; `%20` and `<…>` spellings are decoded, and
//   `#section` or `?query` parts are dropped. A leading "/" means the library
//   root, so links keep working when the library folder moves.
// - A `.md` file inside the library opens as a note in DocType; any other file
//   opens with its default app.
// - Links that only point inside the note (`#heading`) do nothing for now.

import Foundation

public enum LinkTarget: Equatable, Sendable {
    /// A note in the library, by path relative to the library root.
    case note(String)
    /// Anything else, opened with the system.
    case external(URL)

    public static func resolve(_ destination: String, fromNote notePath: String, libraryRoot: URL) -> LinkTarget? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
            return URL(string: trimmed).map(LinkTarget.external)
        }

        var path = trimmed
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<cut]) }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty else { return nil }

        let folder = (notePath as NSString).deletingLastPathComponent
        let joined = path.hasPrefix("/") ? String(path.dropFirst()) : (folder as NSString).appendingPathComponent(path)
        // Resolve "." and ".." without touching the disk.
        var parts: [String] = []
        var leavesLibrary = false
        for part in joined.split(separator: "/") where part != "." {
            if part == ".." {
                if parts.isEmpty { leavesLibrary = true } else { parts.removeLast() }
            } else {
                parts.append(String(part))
            }
        }
        let relative = parts.joined(separator: "/")
        if !leavesLibrary, (relative as NSString).pathExtension.lowercased() == "md" {
            return .note(relative)
        }
        let base = leavesLibrary ? libraryRoot.appending(path: folder) : libraryRoot
        let url = leavesLibrary ? base.appending(path: path).standardizedFileURL : base.appending(path: relative)
        return .external(url)
    }
}
