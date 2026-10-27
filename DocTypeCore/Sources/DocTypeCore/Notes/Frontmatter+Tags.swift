// Writing a note's tags back into its frontmatter.
//
// Only the `tags` entry changes; every other line of the block (other keys,
// comments, blank lines, line endings) stays byte-for-byte, so a git diff after
// adding a tag shows just the tags line. The entry keeps the style it was
// written in: `tags: [a, b]`, `tags: a, b`, or a block list (`- a` lines).
// A note without frontmatter gets `---\ntags: [a]\n---\n`; removing the last
// tag removes the entry, and the whole block if nothing else is left in it.
// Tags are compared ignoring case (`Algo` = `algo`), keeping the first spelling.

import Foundation

extension Frontmatter {
    /// The frontmatter block (`raw`, or none) with its tags set to `tags`.
    /// Returns "" when the block would be empty.
    public static func settingTags(_ tags: [String], in raw: String?) -> String {
        guard let raw, !raw.isEmpty else {
            return tags.isEmpty ? "" : "---\ntags: \(flowList(tags))\n---\n"
        }
        let newline = raw.contains("\r\n") ? "\r\n" : "\n"
        var lines = raw.components(separatedBy: newline)
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        let closing = lines.count - 1  // the closing "---" (or "...")

        if let key = lines[1..<closing].firstIndex(where: { $0.hasPrefix("tags:") }) {
            let value = lines[key].dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
            // A block list's "- item" lines below the key belong to the entry.
            var end = key + 1
            if value.isEmpty { while end < closing, isBlockItem(lines[end]) { end += 1 } }
            let replacement: [String]
            if tags.isEmpty {
                replacement = []
            } else if end > key + 1 {
                let indent = String(lines[key + 1].prefix { $0 == " " || $0 == "\t" })
                replacement = ["tags:"] + tags.map { indent + "- " + quotedIfNeeded($0) }
            } else if !value.isEmpty, !value.hasPrefix("[") {
                replacement = ["tags: " + tags.map(quotedIfNeeded).joined(separator: ", ")]
            } else {
                replacement = ["tags: \(flowList(tags))"]
            }
            lines.replaceSubrange(key..<end, with: replacement)
        } else if !tags.isEmpty {
            lines.insert("tags: \(flowList(tags))", at: closing)
        } else {
            return raw
        }

        let inside = lines.dropFirst().dropLast()
        if inside.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return "" }
        return lines.joined(separator: newline) + (endsWithNewline ? newline : "")
    }

    /// A whole note's text with its tags set (for callers without an editor, like MCP tools).
    public static func settingTags(_ tags: [String], inNote text: String) -> String {
        let (frontmatter, body) = split(text)
        return settingTags(tags, in: frontmatter?.raw) + body
    }

    /// `tags` with `tag` added at the end, unless it's already there in any case.
    public static func adding(_ tag: String, to tags: [String]) -> [String] {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } ? tags : tags + [tag]
    }

    /// `tags` without `tag` (in any case).
    public static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
    }

    /// A tag as typed by the user: trimmed, without a leading "#"; nil if nothing is left.
    public static func cleanedTag(_ typed: String) -> String? {
        var tag = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.trimmingCharacters(in: .whitespaces)
        return tag.isEmpty || tag.contains(where: \.isNewline) ? nil : tag
    }

    // MARK: - Helpers

    private static func flowList(_ tags: [String]) -> String {
        "[" + tags.map(quotedIfNeeded).joined(separator: ", ") + "]"
    }

    private static func isBlockItem(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        return trimmed.hasPrefix("- ") || trimmed == "-"
    }

    /// Quotes a tag that YAML would otherwise read differently ("c++, #x", "a: b").
    private static func quotedIfNeeded(_ tag: String) -> String {
        let special = CharacterSet(charactersIn: ",[]{}:#&*!|>'\"%@`")
        let needsQuotes = tag.unicodeScalars.contains { special.contains($0) }
            || tag.first?.isWhitespace == true || tag.last?.isWhitespace == true || tag.hasPrefix("-")
        guard needsQuotes else { return tag }
        return "\"" + tag.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
