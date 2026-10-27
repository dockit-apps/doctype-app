// Splits YAML frontmatter off the top of a note and reads its `tags` key.
//
// This is deliberately not a YAML parser. We only need `tags`, and keeping the
// block's raw text means we can later rewrite tags without reformatting any
// other keys the user (or another tool) put there.

import Foundation

public struct Frontmatter: Equatable, Sendable {
    /// The whole block exactly as it appears in the file, including both
    /// delimiter lines and the line break after the closing one.
    public var raw: String
    public var tags: [String]

    public init(raw: String, tags: [String]) {
        self.raw = raw
        self.tags = tags
    }

    /// Separates frontmatter from the body. A note has frontmatter only if its
    /// very first line is `---` and a later line is `---` (or YAML's `...`).
    /// An unclosed block is treated as ordinary body text.
    public static func split(_ text: String) -> (frontmatter: Frontmatter?, body: Substring) {
        guard let end = endOfBlock(in: text) else { return (nil, text[...]) }
        let raw = String(text[..<end])
        return (Frontmatter(raw: raw, tags: readTags(from: raw)), text[end...])
    }

    // MARK: - Finding the block

    /// Returns the index just after the closing delimiter line, or nil.
    private static func endOfBlock(in text: String) -> String.Index? {
        guard text.hasPrefix("---"), let first = nextLine(in: text, from: text.startIndex),
              first.line == "---" else { return nil }
        var position = first.next
        while let current = nextLine(in: text, from: position) {
            if current.line == "---" || current.line == "..." { return current.next }
            position = current.next
        }
        return nil
    }

    /// Reads one line starting at `start`, without its `\n` or `\r\n`.
    /// Works on unicode scalars because Swift treats `\r\n` as one Character.
    private static func nextLine(in text: String, from start: String.Index) -> (line: String, next: String.Index)? {
        let scalars = text.unicodeScalars
        guard start < scalars.endIndex else { return nil }
        var end = start
        while end < scalars.endIndex, scalars[end] != "\n" { end = scalars.index(after: end) }
        var line = String(scalars[start..<end])
        if line.hasSuffix("\r") { line.removeLast() }
        let next = end < scalars.endIndex ? scalars.index(after: end) : end
        return (line, next)
    }

    // MARK: - Reading tags

    /// Supports `tags: [a, b]`, `tags: a, b` and the block form:
    /// ```
    /// tags:
    ///   - a
    ///   - b
    /// ```
    static func readTags(from raw: String) -> [String] {
        let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let keyLine = lines.firstIndex(where: { $0.hasPrefix("tags:") }) else { return [] }
        let value = lines[keyLine].dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)

        let items: [Substring]
        if value.hasPrefix("[") {
            items = splitOutsideQuotes(value.dropFirst().prefix { $0 != "]" })
        } else if value.isEmpty {
            items = lines[(keyLine + 1)...]
                .map { $0.drop { $0 == " " || $0 == "\t" } }
                .prefix { $0.hasPrefix("- ") || $0 == "-" }
                .map { $0.dropFirst() }
        } else {
            items = splitOutsideQuotes(value[...])
        }
        return items.map(unquote).filter { !$0.isEmpty }
    }

    /// Splits `a, "b, c", 'd'` at the commas that aren't inside quotes.
    private static func splitOutsideQuotes(_ value: Substring) -> [Substring] {
        var items: [Substring] = []
        var start = value.startIndex, quote: Character?, escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped { escaped = false; continue }
            if let open = quote {
                if character == "\\", open == "\"" { escaped = true } else if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                items.append(value[start..<index])
                start = value.index(after: index)
            }
        }
        items.append(value[start...])
        return items
    }

    private static func unquote(_ item: Substring) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
