// What the note list needs to know about one note: title, snippet, tags, date.
// Built from the note's text with cheap line scanning (no markdown parsing),
// so indexing a whole library stays fast.

import Foundation

public struct NoteSummary: Identifiable, Hashable, Sendable {
    /// Path relative to the library root, e.g. `University/Algorithms/Graphs.md`.
    /// This is the note's identity everywhere (index, selection, future URLs).
    public let path: String
    /// The filename without `.md`.
    public let title: String
    public let snippet: String
    public let tags: [String]
    public let modified: Date

    public var id: String { path }

    /// Folder path of the notebook containing this note; `""` for the library root.
    public var notebook: String { (path as NSString).deletingLastPathComponent }

    public init(path: String, title: String, snippet: String, tags: [String], modified: Date) {
        self.path = path
        self.title = title
        self.snippet = snippet
        self.tags = tags
        self.modified = modified
    }

    public static func make(path: String, text: String, modified: Date) -> NoteSummary {
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let (frontmatter, body) = Frontmatter.split(text)
        return NoteSummary(
            path: path,
            title: title,
            snippet: Snippet.make(from: body, title: title),
            tags: frontmatter?.tags ?? [],
            modified: modified
        )
    }
}

/// Snippet extraction: the text shown under the title in the note list.
///
/// What it does: returns up to `maxLength` characters of the note's first
/// meaningful text as a single plain-text line.
///
/// Rules, and why:
/// - Blank lines, fence lines (```), horizontal rules and HTML comments are
///   skipped. They carry no readable content.
/// - A leading heading that repeats the title is skipped. The title is already
///   shown right above the snippet, and many notes start with `# <title>`.
///   Other headings are kept (minus the `#`) because they often say what the
///   note is about.
/// - Markdown syntax is stripped (heading/quote/list/task markers, `**`, `` ` ``,
///   `~~`, `*x*`, links become their text), so the list reads like prose.
///   `_x_` is left alone so `snake_case` identifiers survive.
/// - Code inside fences is kept. For engineering notes, the code is often the
///   most recognizable part.
///
/// Alternatives considered:
/// - First paragraph only (Apple Notes style): too short when notes start with
///   a one-line heading.
/// - Rendering with swift-markdown and taking plain text: exact, but parsing
///   every note during indexing would blow the launch budget.
/// - Skipping code blocks: hides the content of code-heavy notes.
enum Snippet {
    static let maxLength = 200

    static func make(from body: Substring, title: String) -> String {
        var parts: [String] = []
        var length = 0
        var isFirstContentLine = true

        for rawLine in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isFenceOrRule(line) || line.hasPrefix("<!--") { continue }

            let text = plainText(line)
            defer { isFirstContentLine = false }
            if isFirstContentLine, line.hasPrefix("#"),
               text.caseInsensitiveCompare(title) == .orderedSame { continue }
            if text.isEmpty { continue }

            parts.append(text)
            length += text.count + 1
            if length >= maxLength { break }
        }
        let joined = parts.joined(separator: " ")
        return joined.count > maxLength ? String(joined.prefix(maxLength)) : joined
    }

    private static func isFenceOrRule(_ line: String) -> Bool {
        if line.hasPrefix("```") || line.hasPrefix("~~~") { return true }
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && ["-", "*", "_"].contains { marker in
            compact.allSatisfy { String($0) == marker }
        }
    }

    /// Removes markdown syntax from one line.
    static func plainText(_ line: String) -> String {
        var text = Substring(line)
        // Block prefixes can nest (`> - [ ] task`), so strip until nothing changes.
        while true {
            let before = text
            text = text.drop { $0 == " " }
            if text.hasPrefix(">") { text = text.dropFirst() }
            else if let range = text.firstMatch(of: #/^#{1,6}\s+/#)?.range { text = text[range.upperBound...] }
            else if let range = text.firstMatch(of: #/^([-*+]|\d+[.)])\s+/#)?.range { text = text[range.upperBound...] }
            else if let range = text.firstMatch(of: #/^\[[ xX]\]\s+/#)?.range { text = text[range.upperBound...] }
            if text == before { break }
        }
        var result = String(text)
        result.replace(#/!?\[([^\]]*)\]\([^)]*\)/#) { String($0.output.1) }
        for marker in ["**", "__", "~~", "`"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        result.replace(#/\*([^*\s][^*]*)\*/#) { String($0.output.1) }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
