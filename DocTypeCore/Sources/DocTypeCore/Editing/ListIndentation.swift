// Tab and Shift-Tab on list items (bullets, numbers, tasks): move the item one level
// in or out, together with everything nested under it, and keep every list it
// touches numbered in order.
// - Tab makes the item a child of the item above it at the same level. A new
//   sub-list starts at 1; joining an existing sub-list continues its numbers.
// - Shift-Tab makes the item a sibling of its parent, numbered after it. Items that
//   were below it at its old level become its children, starting again at 1.
// - The items left behind are renumbered: Tab on "2." of "1. 2. 3." gives
//   "1. (1.) 2.", so the sub-list never changes the numbers around it.
// - The cursor stays in the same place in the item's text.
// Tab on a list's first item (no item above to nest under) and Shift-Tab on a
// top-level item change nothing, rather than typing a tab into the marker.
//
// A child is indented to where its parent's text starts ("- " → 2 spaces, "1. " →
// 3), which is what markdown needs to nest it; an existing sub-list's indentation
// wins. Numbers are renumbered from the moved item down to the end of the list.
//
// Alternatives considered: indenting by a fixed tab or 4 spaces (simpler, but
// "1. " then needs 3, "- " needs 2, and a tab doesn't always nest in other apps);
// keeping numbers as typed (then the preview disagrees with the editor).

import Foundation

public enum ListIndentation {
    public enum Direction: Sendable { case indent, outdent }

    /// What Tab (`.indent`) or Shift-Tab (`.outdent`) does at `selection`, or nil
    /// if the cursor isn't on a list item (the key then works as usual). An edit
    /// that changes nothing (`isNoChange`) means "swallow the key".
    public static func edit(
        _ direction: Direction, in text: NSString, selection: NSRange, blockMap: BlockMap
    ) -> TextEdit? {
        if let block = blockMap.blocks(in: NSRange(location: selection.location, length: 0)).first,
           case .code = block.kind { return nil }
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let target = ListLine(text.substring(with: lineRange))
        guard target.isItem,
              NSMaxRange(selection) <= lineRange.location + target.lengthWithoutBreak else { return nil }

        var (lines, start, index) = region(around: lineRange, quote: target.quote, in: text)
        let unchanged = TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "",
                                 selectionAfter: selection)
        let oldIndent = lines[index].indent
        guard let newIndent = direction == .indent ? indentUnderPreviousSibling(index, in: lines)
                                                   : indentOfParent(index, in: lines) else { return unchanged }

        // Move the item and the lines nested under it.
        let width = indentWidth(oldIndent)
        var end = index + 1
        while end < lines.count, indentWidth(lines[end].indent) > width { end += 1 }
        for moved in index..<end {
            let indent = lines[moved].indent
            lines[moved].indent = indent.hasPrefix(oldIndent)
                ? newIndent + indent.dropFirst(oldIndent.count)
                : String(repeating: " ", count: max(0, indentWidth(indent) - width + indentWidth(newIndent)))
        }
        renumber(&lines, from: index)

        // Replace from the item's line to the last line that changed.
        var oldTexts: [String] = []
        var location = start
        for _ in lines {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            oldTexts.append(text.substring(with: range))
            location = NSMaxRange(range)
        }
        let newTexts = lines.map(\.text)
        guard let last = newTexts.indices.last(where: { newTexts[$0] != oldTexts[$0] }), last >= index else {
            return unchanged
        }
        let editStart = start + oldTexts[..<index].reduce(0) { $0 + $1.utf16.count }
        let editLength = oldTexts[index...last].reduce(0) { $0 + $1.utf16.count }
        let shift = lines[index].markerEnd - target.markerEnd
        let column = selection.location - lineRange.location
        let newColumn = column >= target.markerEnd ? column + shift : min(column, lines[index].markerEnd)
        return TextEdit(range: NSRange(location: editStart, length: editLength),
                        replacement: newTexts[index...last].joined(),
                        selectionAfter: NSRange(location: editStart + max(newColumn, 0), length: selection.length))
    }

    // MARK: - Finding where the item goes

    /// Tab: the indentation of the previous sibling's children (an existing
    /// sub-list's, or the sibling's text start); nil if there's no previous sibling.
    private static func indentUnderPreviousSibling(_ index: Int, in lines: [ListLine]) -> String? {
        let width = indentWidth(lines[index].indent)
        var childIndent: String?
        for line in lines[..<index].reversed() where line.isItem {
            let lineWidth = indentWidth(line.indent)
            if lineWidth > width {
                if childIndent.map({ lineWidth <= indentWidth($0) }) ?? true { childIndent = line.indent }
                continue
            }
            guard lineWidth == width else { return nil }  // reached the parent: no sibling above
            return childIndent ?? line.indent + String(repeating: " ", count: line.contentOffset)
        }
        return nil
    }

    /// Shift-Tab: the parent's indentation; nil for a top-level item.
    private static func indentOfParent(_ index: Int, in lines: [ListLine]) -> String? {
        let width = indentWidth(lines[index].indent)
        return lines[..<index].reversed().first { $0.isItem && indentWidth($0.indent) < width }?.indent
    }

    /// Numbers items in order from `index` on. Each list continues from the item
    /// before it at the same level; a list that starts at or after `index` starts at 1.
    private static func renumber(_ lines: inout [ListLine], from index: Int) {
        var levels: [(width: Int, symbol: String, number: Int?)] = []
        for position in lines.indices where lines[position].isItem {
            let width = indentWidth(lines[position].indent)
            while let level = levels.last, level.width > width { levels.removeLast() }
            var previous: Int?
            if let level = levels.last, level.width == width {
                if level.symbol == lines[position].symbol { previous = level.number }
                levels.removeLast()
            }
            if position >= index, lines[position].number != nil {
                lines[position].number = previous.map { $0 + 1 } ?? 1
            }
            levels.append((width, lines[position].symbol, lines[position].number))
        }
    }

    // MARK: - Reading the list

    /// The list's lines around `lineRange`: list items and indented lines with the
    /// same quote prefix, up to a blank line or anything else. Returns the lines,
    /// the location of the first one, and the index of the line at `lineRange`.
    private static func region(around lineRange: NSRange, quote: String, in text: NSString)
        -> (lines: [ListLine], start: Int, index: Int) {
        func belongs(_ line: ListLine) -> Bool {
            guard line.quote == quote else { return false }
            return line.isItem || (indentWidth(line.indent) > 0 && !line.isBlank)
        }
        var start = lineRange.location
        var before: [ListLine] = []
        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            let line = ListLine(text.substring(with: previous))
            guard belongs(line) else { break }
            before.insert(line, at: 0)
            start = previous.location
        }
        var lines = before + [ListLine(text.substring(with: lineRange))]
        var location = NSMaxRange(lineRange)
        while location < text.length {
            let next = text.lineRange(for: NSRange(location: location, length: 0))
            let line = ListLine(text.substring(with: next))
            guard belongs(line) else { break }
            lines.append(line)
            location = NSMaxRange(next)
        }
        return (lines, start, before.count)
    }

    /// Columns an indentation takes, with tabs to the next multiple of 4.
    static func indentWidth(_ indent: String) -> Int {
        indent.reduce(0) { $1 == "\t" ? ($0 / 4 + 1) * 4 : $0 + 1 }
    }
}

/// One line of a list, split into its parts so it can be re-indented and renumbered.
struct ListLine {
    var quote: String
    var indent: String
    /// For list items: the number, if numbered.
    var number: Int?
    /// For list items: the bullet, or the delimiter after the number. Empty for other lines.
    var symbol: String
    /// Everything after the marker (or after the indentation, for other lines), with the line break.
    var rest: String

    var isItem: Bool { !symbol.isEmpty }
    var isBlank: Bool { rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var text: String { quote + indent + (number.map(String.init) ?? "") + symbol + rest }
    /// Where the marker ends, from the start of the line (UTF-16).
    var markerEnd: Int { (quote + indent + (number.map(String.init) ?? "") + symbol).utf16.count }
    var lengthWithoutBreak: Int { text.utf16.count - String(text.reversed().prefix(while: \.isNewline)).utf16.count }
    /// How far a child's indentation goes past this item's: the marker and the spaces after it.
    var contentOffset: Int {
        (number.map(String.init) ?? "").count + symbol.count + rest.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static let item = try! NSRegularExpression(
        pattern: "^((?: {0,3}>[ \\t])*)([ \\t]*)(?:([-*+])|([0-9]{1,9})([.)]))(?=[ \\t])")
    private static let other = try! NSRegularExpression(pattern: "^((?: {0,3}>[ \\t])*)([ \\t]*)")
    private static let thematicBreak = try! NSRegularExpression(pattern: "^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")

    /// Parses one line (with its line break). Lines that aren't list items get an empty symbol.
    init(_ line: String) {
        let string = line as NSString
        let whole = NSRange(location: 0, length: string.length)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : string.substring(with: range)
        }
        let content = line.trimmingCharacters(in: .newlines)
        if let match = Self.item.firstMatch(in: line, range: whole) {
            let quote = group(match, 1) ?? ""
            let afterQuote = String(content.dropFirst(quote.count))
            if Self.thematicBreak.firstMatch(in: afterQuote, range: NSRange(location: 0, length: (afterQuote as NSString).length)) == nil {
                self.quote = quote
                indent = group(match, 2) ?? ""
                number = group(match, 4).flatMap { Int($0) }
                symbol = group(match, 3) ?? group(match, 5) ?? ""
                rest = string.substring(from: match.range.length)
                return
            }
        }
        let match = Self.other.firstMatch(in: line, range: whole)!
        quote = group(match, 1) ?? ""
        indent = group(match, 2) ?? ""
        number = nil
        symbol = ""
        rest = string.substring(from: match.range.length)
    }
}
