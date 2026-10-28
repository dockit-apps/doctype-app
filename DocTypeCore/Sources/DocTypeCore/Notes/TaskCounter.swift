// Counts a note's task items ("- [ ] a", "- [x] b") for the progress shown in
// the note list. A plain line scan, like the snippet, so indexing stays fast.
//
// Counted: list items of any marker (-, *, +, 1., 1)) at any indentation, also
// inside block quotes, whose text starts with "[ ]", "[x]" or "[X]" followed by
// a space or the end of the line. That is what GitHub renders as a checkbox.
// Not counted: anything inside a fenced code block (``` or ~~~), so a note
// documenting markdown syntax doesn't show tasks it doesn't have.
// Indented code blocks aren't detected: nested list items are indented the same
// way, and telling them apart needs a real parse.

import Foundation

public struct TaskProgress: Hashable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public static let none = TaskProgress(done: 0, total: 0)
}

enum TaskCounter {
    /// The tasks in a note's body (frontmatter already removed).
    static func count(in body: Substring) -> TaskProgress {
        var progress = TaskProgress.none
        var openFence: (character: Character, length: Int)?

        for line in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if let fence = fence(in: line) {
                if let open = openFence {
                    // Only a bare fence of the same kind, at least as long, closes it.
                    if fence.character == open.character, fence.length >= open.length, fence.isBare { openFence = nil }
                } else {
                    openFence = (fence.character, fence.length)
                }
                continue
            }
            guard openFence == nil, let isDone = taskState(of: line) else { continue }
            progress.total += 1
            if isDone { progress.done += 1 }
        }
        return progress
    }

    /// A fence line: up to 3 spaces, then 3 or more ` or ~.
    private static func fence(in line: Substring) -> (character: Character, length: Int, isBare: Bool)? {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3 else { return nil }
        let rest = line[indent.endIndex...]
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let run = rest.prefix { $0 == character }
        guard run.count >= 3 else { return nil }
        let info = rest[run.endIndex...]
        if character == "`", info.contains("`") { return nil }  // inline code, not a fence
        return (character, run.count, info.allSatisfy { $0 == " " || $0 == "\t" })
    }

    /// true for a checked task line, false for an open one, nil for anything else.
    private static func taskState(of line: Substring) -> Bool? {
        var text = line.drop { $0 == " " || $0 == "\t" }
        while text.first == ">" { text = text.dropFirst().drop { $0 == " " || $0 == "\t" } }

        guard let marker = text.first else { return nil }
        if marker == "-" || marker == "*" || marker == "+" {
            text = text.dropFirst()
        } else if marker.isASCII, marker.isNumber {
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9, digits.endIndex < text.endIndex,
                  text[digits.endIndex] == "." || text[digits.endIndex] == ")" else { return nil }
            text = text[text.index(after: digits.endIndex)...]
        } else {
            return nil
        }
        guard text.first == " " || text.first == "\t" else { return nil }
        text = text.drop { $0 == " " || $0 == "\t" }

        let box = text.prefix(3)
        guard box.count == 3 else { return nil }
        let afterBox = text.dropFirst(3)
        guard afterBox.isEmpty || afterBox.first == " " || afterBox.first == "\t" else { return nil }
        switch box {
        case "[ ]": return false
        case "[x]", "[X]": return true
        default: return nil
        }
    }
}
