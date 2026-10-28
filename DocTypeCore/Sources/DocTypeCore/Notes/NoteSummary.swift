// What the note list needs to know about one note: title, snippet, tags, tasks,
// date, plus the folded text that search looks in.
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
    /// Checked and total task items, for the progress shown in the list.
    public let tasks: TaskProgress
    public let modified: Date
    /// The whole text (title, frontmatter and body) folded for searching; see NoteSearch.
    let searchText: String
    let searchTitle: String

    public var id: String { path }

    /// Folder path of the notebook containing this note; `""` for the library root.
    public var notebook: String { (path as NSString).deletingLastPathComponent }

    public init(path: String, title: String, snippet: String, tags: [String],
                tasks: TaskProgress = .none, modified: Date, searchText: String = "") {
        self.path = path
        self.title = title
        self.snippet = snippet
        self.tags = tags
        self.tasks = tasks
        self.modified = modified
        self.searchTitle = NoteSearch.fold(title)
        self.searchText = searchText.isEmpty ? searchTitle : searchText
    }

    public static func make(path: String, text: String, modified: Date) -> NoteSummary {
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let (frontmatter, body) = Frontmatter.split(text)
        return NoteSummary(
            path: path,
            title: title,
            snippet: Snippet.make(from: body, title: title),
            tags: frontmatter?.tags ?? [],
            tasks: TaskCounter.count(in: body),
            modified: modified,
            searchText: NoteSearch.fold(title + "\n" + text)
        )
    }

    /// The note list's order: most recently modified first, then by title.
    public static func newestFirst(_ lhs: NoteSummary, _ rhs: NoteSummary) -> Bool {
        lhs.modified != rhs.modified ? lhs.modified > rhs.modified
            : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
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
    /// Plain character scanning rather than Swift Regex: with Regex, scanning
    /// the 1,000-note fixture took 600 ms instead of about 240 ms.
    static func plainText(_ line: String) -> String {
        var text = Substring(line)
        // Block prefixes can nest (`> - [ ] task`), so strip until nothing changes.
        while true {
            text = text.drop { $0 == " " }
            if text.hasPrefix(">") { text = text.dropFirst(); continue }
            if let rest = dropBlockMarker(text) { text = rest; continue }
            break
        }
        return stripInlineMarkers(text).trimmingCharacters(in: .whitespaces)
    }

    /// Drops one `# `, `- `, `* `, `+ `, `1. `, `1) ` or `[ ] ` prefix, if present.
    private static func dropBlockMarker(_ text: Substring) -> Substring? {
        func afterSpace(_ index: Substring.Index) -> Substring? {
            guard index < text.endIndex, text[index] == " " || text[index] == "\t" else { return nil }
            return text[text.index(after: index)...]
        }
        guard let first = text.first else { return nil }
        if first == "#" {
            let hashes = text.prefix { $0 == "#" }
            return hashes.count <= 6 ? afterSpace(hashes.endIndex) : nil
        }
        if first == "-" || first == "*" || first == "+" {
            return afterSpace(text.index(after: text.startIndex))
        }
        if first.isNumber {
            let digits = text.prefix { $0.isNumber }
            guard digits.endIndex < text.endIndex, text[digits.endIndex] == "." || text[digits.endIndex] == ")" else { return nil }
            return afterSpace(text.index(after: digits.endIndex))
        }
        if text.hasPrefix("[ ]") || text.hasPrefix("[x]") || text.hasPrefix("[X]") {
            return afterSpace(text.index(text.startIndex, offsetBy: 3))
        }
        return nil
    }

    /// `[text](url)` → `text`; removes `` ` ``, `**`, `__`, `~~` and emphasis `*`.
    /// A lone `*` between spaces (`5 * 3`) and single `_` (`snake_case`) are kept.
    private static func stripInlineMarkers(_ text: Substring) -> String {
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)
        var i = 0
        while i < characters.count {
            let character = characters[i]
            let next: Character? = i + 1 < characters.count ? characters[i + 1] : nil
            let previous: Character? = i > 0 ? characters[i - 1] : nil

            if character == "[" || (character == "!" && next == "["),
               let link = linkText(in: characters, openingAt: character == "!" ? i + 1 : i) {
                // An image's "alt|300" width isn't part of its text.
                result += character == "!" ? ImageSizing.parse(alt: link.text).alt : link.text
                i = link.end
                continue
            }
            if (character == "_" && next == "_") || (character == "~" && next == "~") {
                i += 2
                continue
            }
            let isLoneAsterisk = character == "*" && previous == " " && (next == " " || next == nil)
            if character == "`" || (character == "*" && !isLoneAsterisk) {
                i += 1
                continue
            }
            result.append(character)
            i += 1
        }
        return result
    }

    /// For `[text](url)` starting at `open`, returns `text` and the index after `)`.
    private static func linkText(in characters: [Character], openingAt open: Int) -> (text: String, end: Int)? {
        guard let close = characters[open...].firstIndex(of: "]"),
              close + 1 < characters.count, characters[close + 1] == "(",
              let end = characters[(close + 1)...].firstIndex(of: ")") else { return nil }
        return (String(characters[(open + 1)..<close]), end + 1)
    }
}
