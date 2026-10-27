// The Format menu as pure text transforms: bold, italic, inline code, link,
// headings and task items. Each returns one TextEdit, so the app applies it as
// one undo step, and MCP tools can call the same functions later.
//
// - Bold, italic and code work on the selection, or on the word at the cursor.
//   If the text is already wrapped in the marker, it's unwrapped (a toggle).
//   Bold and italic share "*", so the number of stars decides: "***x***" is both.
// - With no word at the cursor, an empty pair is inserted ("**|**"); the same
//   command on an empty pair removes it again.
// - Headings and task items work on every line the selection touches. Choosing
//   the level a line already has turns it back into body text.

import Foundation

public enum Formatting {
    public enum InlineStyle: Sendable {
        case strong, emphasis, code

        var marker: String {
            switch self {
            case .strong: "**"
            case .emphasis: "*"
            case .code: "`"
            }
        }
    }

    // MARK: - Bold, italic, code

    public static func toggle(_ style: InlineStyle, in text: NSString, selection: NSRange) -> TextEdit {
        let marker = style.marker
        let length = (marker as NSString).length
        let markerCharacter = (marker as NSString).character(at: 0)
        let range = selection.length > 0 ? selection : word(at: selection.location, in: text)

        if range.length == 0 {
            // No word here: insert an empty pair, or remove one the cursor is in.
            let location = range.location
            if run(of: markerCharacter, endingAt: location, in: text) >= length,
               run(of: markerCharacter, startingAt: location, in: text) >= length {
                return TextEdit(range: NSRange(location: location - length, length: 2 * length), replacement: "",
                                selectionAfter: NSRange(location: location - length, length: 0))
            }
            return TextEdit(range: range, replacement: marker + marker,
                            selectionAfter: NSRange(location: location + length, length: 0))
        }

        // Markers just outside the range: "**|word|**".
        let outside = min(run(of: markerCharacter, endingAt: range.location, in: text),
                          run(of: markerCharacter, startingAt: NSMaxRange(range), in: text))
        if style.isPresent(withMarkerRun: outside) {
            let wrapped = NSRange(location: range.location - length, length: range.length + 2 * length)
            return TextEdit(range: wrapped, replacement: text.substring(with: range),
                            selectionAfter: shifted(selection, by: -length))
        }
        // Markers selected along with the text: "|**word**|".
        let inner = text.substring(with: range) as NSString
        let inside = min(run(of: markerCharacter, startingAt: 0, in: inner),
                         run(of: markerCharacter, endingAt: inner.length, in: inner))
        if inner.length > 2 * length, style.isPresent(withMarkerRun: inside) {
            let unwrapped = inner.substring(with: NSRange(location: length, length: inner.length - 2 * length))
            return TextEdit(range: range, replacement: unwrapped,
                            selectionAfter: NSRange(location: range.location, length: (unwrapped as NSString).length))
        }
        return TextEdit(range: range, replacement: marker + (inner as String) + marker,
                        selectionAfter: shifted(selection, by: length))
    }

    // MARK: - Link

    /// `[selection](|)` with the cursor where the URL goes; a selected URL becomes
    /// `[|](url)` instead; with nothing selected, `[|]()`.
    public static func link(in text: NSString, selection: NSRange) -> TextEdit {
        let selected = text.substring(with: selection)
        if selected.isEmpty {
            return TextEdit(range: selection, replacement: "[]()",
                            selectionAfter: NSRange(location: selection.location + 1, length: 0))
        }
        if isURL(selected) {
            return TextEdit(range: selection, replacement: "[](\(selected))",
                            selectionAfter: NSRange(location: selection.location + 1, length: 0))
        }
        let replacement = "[\(selected)]()"
        return TextEdit(range: selection, replacement: replacement,
                        selectionAfter: NSRange(location: selection.location + (replacement as NSString).length - 1, length: 0))
    }

    // MARK: - Headings and task items

    /// Heading `level` (1–6) on the selected lines, or body text for 0. If every
    /// line already has that level, they become body text.
    public static func heading(_ level: Int, in text: NSString, selection: NSRange) -> TextEdit {
        let headingPrefix = try! NSRegularExpression(pattern: "^#{1,6}(?:[ \\t]+|$)")
        func currentLevel(_ line: String) -> (level: Int, prefixLength: Int) {
            let ns = line as NSString
            let match = headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
            guard let match else { return (0, 0) }
            return (line.prefix { $0 == "#" }.count, match.range.length)
        }
        let lines = selectedLines(in: text, selection: selection)
        let allAtLevel = lines.allSatisfy { currentLevel($0.content).level == level }
        let target = allAtLevel ? 0 : level
        let newPrefix = target == 0 ? "" : String(repeating: "#", count: target) + " "
        return editLines(lines, in: text, selection: selection) { _, content in
            (currentLevel(content).prefixLength, newPrefix)
        }
    }

    /// Turns the selected lines into tasks ("- [ ] "), keeping list markers,
    /// indentation and quotes. If they're all tasks already, removes the boxes.
    public static func toggleTask(in text: NSString, selection: NSRange) -> TextEdit {
        let lines = selectedLines(in: text, selection: selection)
        let parsed = lines.map { ListLine($0.content) }
        let allTasks = parsed.allSatisfy { $0.isItem && taskBox(in: $0.rest) != nil }
        return editLines(lines, in: text, selection: selection) { index, _ in
            let line = parsed[index]
            let lead = line.quote + line.indent
            guard line.isItem else {
                return allTasks ? nil : ((lead as NSString).length, lead + "- [ ] ")
            }
            let marker = lead + (line.number.map(String.init) ?? "") + line.symbol
            let spacing = String(line.rest.prefix { $0 == " " || $0 == "\t" })
            let markerLength = (marker as NSString).length + (spacing as NSString).length
            if let box = taskBox(in: line.rest) {
                return allTasks ? (markerLength + box, marker + spacing) : nil
            }
            return (markerLength, marker + spacing + "[ ] ")
        }
    }

    // MARK: - Helpers

    private struct Line {
        /// Without the line break.
        let range: NSRange
        let content: String
    }

    /// The lines the selection touches. Blank lines are skipped when there are
    /// several, so a heading isn't added to the gaps between paragraphs.
    private static func selectedLines(in text: NSString, selection: NSRange) -> [Line] {
        var lines: [Line] = []
        let end = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        var location = selection.location
        repeat {
            var start = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&start, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: min(location, text.length), length: 0))
            let range = NSRange(location: start, length: contentsEnd - start)
            lines.append(Line(range: range, content: text.substring(with: range)))
            location = lineEnd
        } while location <= end && location < text.length
        let nonBlank = lines.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.count > 1 && !nonBlank.isEmpty ? nonBlank : lines
    }

    /// Replaces each line's prefix: `change` gets the line's index and text and
    /// returns (length of the old prefix, new prefix), or nil to leave the line
    /// alone. The selection moves with the text.
    private static func editLines(
        _ lines: [Line], in text: NSString, selection: NSRange, change: (Int, String) -> (Int, String)?
    ) -> TextEdit {
        let start = lines.first!.range.location, end = NSMaxRange(lines.last!.range)
        var replacement = ""
        var cursor = start
        var mapped = (selection.location, NSMaxRange(selection))
        var delta = 0
        for (index, line) in lines.enumerated() {
            replacement += text.substring(with: NSRange(location: cursor, length: line.range.location - cursor))
            let (oldLength, newPrefix) = change(index, line.content) ?? (0, "")
            let newLength = (newPrefix as NSString).length
            replacement += newPrefix + (line.content as NSString).substring(from: oldLength)
            func map(_ position: Int, keepingLineStart: Bool) -> Int? {
                guard position >= line.range.location, position <= NSMaxRange(line.range) else { return nil }
                let column = position - line.range.location
                if keepingLineStart, column <= oldLength { return line.range.location + delta }
                return line.range.location + delta + (column < oldLength ? newLength : column - oldLength + newLength)
            }
            // A selection starting in the prefix keeps the whole line selected; a
            // cursor there moves after the new prefix, ready to type.
            if let new = map(selection.location, keepingLineStart: selection.length > 0) { mapped.0 = new }
            if let new = map(NSMaxRange(selection), keepingLineStart: false) { mapped.1 = new }
            delta += newLength - oldLength
            cursor = NSMaxRange(line.range)
        }
        if NSMaxRange(selection) > end { mapped.1 = NSMaxRange(selection) + delta }
        return TextEdit(range: NSRange(location: start, length: end - start), replacement: replacement,
                        selectionAfter: NSRange(location: mapped.0, length: max(mapped.1 - mapped.0, 0)))
    }

    /// Length of "[ ] " (box and spaces) after a list marker's spacing, if any.
    private static func taskBox(in rest: String) -> Int? {
        let ns = rest as NSString
        let match = (try! NSRegularExpression(pattern: "^[ \\t]+(\\[[ xX]\\][ \\t]+)"))
            .firstMatch(in: rest, range: NSRange(location: 0, length: ns.length))
        return match.map { $0.range(at: 1).length }
    }

    /// The word around `location`: letters, digits, "_" and "-"; empty in whitespace.
    private static func word(at location: Int, in text: NSString) -> NSRange {
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-'"))
        func isWord(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return true }  // surrogates: part of a word
            return wordCharacters.contains(scalar)
        }
        var start = location, end = location
        while start > 0, isWord(start - 1) { start -= 1 }
        while end < text.length, isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func run(of character: unichar, endingAt location: Int, in text: NSString) -> Int {
        var count = 0
        while location - count > 0, text.character(at: location - count - 1) == character { count += 1 }
        return count
    }

    private static func run(of character: unichar, startingAt location: Int, in text: NSString) -> Int {
        var count = 0
        while location + count < text.length, text.character(at: location + count) == character { count += 1 }
        return count
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func isURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        return !trimmed.contains(" ") && (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("www.") || trimmed.hasPrefix("mailto:"))
    }
}

extension Formatting.InlineStyle {
    /// Whether text between `run` marker characters on each side has this style:
    /// one star is italic, two bold, three both.
    func isPresent(withMarkerRun run: Int) -> Bool {
        switch self {
        case .code: run >= 1
        case .strong: run >= 2
        case .emphasis: run == 1 || run >= 3
        }
    }
}
