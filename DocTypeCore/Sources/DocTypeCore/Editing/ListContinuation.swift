// How Return and the cursor behave on list items ("- ", "* ", "+ ", "1. ", "1) ")
// and tasks ("- [ ] ").
// - Return on an item with text starts the next item: same indentation and bullet,
//   the next number, and an unchecked box for tasks. Text after the cursor moves
//   into the new item. Numbered items below that would now repeat a number are
//   renumbered in the same edit.
// - Return on an empty item ends the list: the marker is removed and the cursor
//   stays on the now-empty line.
// - A "> " quote prefix is kept, so lists inside quotes continue too.
// - Backspace right after a task's box turns the task back into a plain item.
// - The cursor never stops inside a task's "- [ ] " (it's hidden behind the drawn
//   checkbox), the same way QuoteEditing keeps it out of "> ".
//
// Alternatives considered: on an empty nested item, outdent one level (Obsidian)
// instead of ending the list — nicer for deep lists but needs the parent's marker
// and indentation; Tab/Shift-Tab can cover that later. Not renumbering at all is
// simpler but leaves "1. 2. 2. 3." after inserting in the middle.

import Foundation

public enum ListContinuation {
    /// What Return should do at `selection`, or nil to leave it to the next rule.
    public static func editForNewline(in text: NSString, selection: NSRange, blockMap: BlockMap) -> TextEdit? {
        guard let item = listItem(at: selection.location, in: text, blockMap: blockMap),
              selection.location >= item.contentStart, NSMaxRange(selection) <= NSMaxRange(item.range) else { return nil }
        if item.isEmpty {
            // Return on an empty item: drop the marker, keep any quote prefix.
            let marker = NSRange(location: item.markerStart, length: NSMaxRange(item.range) - item.markerStart)
            return TextEdit(range: marker, replacement: "",
                            selectionAfter: NSRange(location: item.markerStart, length: 0))
        }
        let next = item.number.map { "\($0 + 1)\(item.delimiter)" } ?? item.delimiter
        let inserted = "\n" + item.prefix + next + item.spacing + (item.hasBox ? "[ ]" + item.boxSpacing : "")
        let insertedLength = (inserted as NSString).length
        let selectionAfter = NSRange(location: selection.location + insertedLength, length: 0)

        // Renumber the following siblings that would now repeat or go backwards.
        guard let number = item.number,
              let renumbered = renumbering(after: item, from: number + 2, in: text, blockMap: blockMap) else {
            return TextEdit(range: selection, replacement: inserted, selectionAfter: selectionAfter)
        }
        let tail = text.substring(with: NSRange(location: NSMaxRange(selection),
                                                length: renumbered.range.location - NSMaxRange(selection)))
        return TextEdit(range: NSRange(location: selection.location, length: NSMaxRange(renumbered.range) - selection.location),
                        replacement: inserted + tail + renumbered.text, selectionAfter: selectionAfter)
    }

    /// What Backspace should do at `selection`, or nil for a normal backspace.
    public static func editForBackspace(in text: NSString, selection: NSRange, blockMap: BlockMap) -> TextEdit? {
        guard selection.length == 0, let item = listItem(at: selection.location, in: text, blockMap: blockMap),
              item.hasBox, selection.location == item.contentStart else { return nil }
        let box = NSRange(location: item.boxStart, length: item.contentStart - item.boxStart)
        return TextEdit(range: box, replacement: "", selectionAfter: NSRange(location: item.boxStart, length: 0))
    }

    /// Keeps a cursor out of a task's hidden "- [ ] ": moving forward (or clicking)
    /// into it lands at the task's text; moving backward from the text goes to the
    /// end of the previous line.
    public static func adjustedSelection(
        from old: NSRange, to new: NSRange, in text: NSString, blockMap: BlockMap
    ) -> NSRange {
        guard new.length == 0, let item = listItem(at: new.location, in: text, blockMap: blockMap), item.hasBox,
              new.location > item.markerStart, new.location < item.contentStart else { return new }
        let movingBack = old.length == 0 && old.location == item.contentStart && new.location < old.location
        if movingBack, item.range.location > 0 {
            return NSRange(location: item.range.location - 1, length: 0)
        }
        return NSRange(location: item.contentStart, length: 0)
    }

    // MARK: - Parsing a list line

    struct ListItem {
        /// The line without its line break.
        let range: NSRange
        /// Quote prefix and indentation, repeated on the next item.
        let prefix: String
        /// Where the bullet or number starts.
        let markerStart: Int
        /// After the bullet, or after the number's delimiter.
        let markerEnd: Int
        /// The bullet ("-", "*", "+") or the delimiter after the number ("." or ")").
        let delimiter: String
        let number: Int?
        let spacing: String
        /// Where "[ ]" starts, if this is a task.
        let boxStart: Int
        let hasBox: Bool
        let boxSpacing: String
        let contentStart: Int
        let isEmpty: Bool
    }

    /// Quote prefix, indentation, bullet or number, spaces, optional "[ ]" + spaces.
    /// The marker counts only with a space after it, as in the styling.
    private static let pattern = try! NSRegularExpression(
        pattern: "^((?: {0,3}>[ \\t])*)([ \\t]*)(?:([-*+])|([0-9]{1,9})([.)]))([ \\t]+)(?:\\[[ xX]\\]([ \\t]+))?")
    private static let thematicBreak = try! NSRegularExpression(pattern: "^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")

    static func listItem(at location: Int, in text: NSString, blockMap: BlockMap) -> ListItem? {
        guard location <= text.length else { return nil }
        if let block = blockMap.blocks(in: NSRange(location: location, length: 0)).first, case .code = block.kind {
            return nil  // "- " inside a code block is just code
        }
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        let range = NSRange(location: start, length: contentsEnd - start)
        let line = text.substring(with: range) as NSString
        let whole = NSRange(location: 0, length: line.length)
        guard let match = pattern.firstMatch(in: line as String, range: whole) else { return nil }
        let quote = match.range(at: 1)
        let afterQuote = NSRange(location: quote.length, length: line.length - quote.length)
        guard thematicBreak.firstMatch(in: line as String, range: afterQuote) == nil else { return nil }  // "- - -"

        func group(_ index: Int) -> String? {
            let groupRange = match.range(at: index)
            return groupRange.location == NSNotFound ? nil : line.substring(with: groupRange)
        }
        let markerStart = match.range(at: 2).upperBound
        let boxSpacing = group(7)
        let boxStart = match.range(at: 6).upperBound
        let content = line.substring(from: match.range.length).trimmingCharacters(in: .whitespaces)
        return ListItem(
            range: range, prefix: line.substring(to: markerStart), markerStart: start + markerStart,
            markerEnd: start + match.range(at: 6).location, delimiter: group(3) ?? group(5) ?? "", number: group(4).flatMap { Int($0) }, spacing: group(6) ?? " ",
            boxStart: start + boxStart, hasBox: boxSpacing != nil, boxSpacing: boxSpacing ?? "",
            contentStart: start + match.range.length, isEmpty: content.isEmpty)
    }

    /// New text for the numbered siblings below `item` that would otherwise repeat
    /// a number or go backwards, numbered from `first`; nil if none need it.
    /// Nested lines between them are kept as they are; anything else ends the list.
    private static func renumbering(
        after item: ListItem, from first: Int, in text: NSString, blockMap: BlockMap
    ) -> (range: NSRange, text: String)? {
        var expected = first
        var location = NSMaxRange(text.lineRange(for: item.range))
        var start: Int?, end = 0
        var result = "", nested = ""
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange)
            if let sibling = listItem(at: location, in: text, blockMap: blockMap), sibling.prefix == item.prefix {
                guard let number = sibling.number, sibling.delimiter == item.delimiter, number < expected else { break }
                start = start ?? lineRange.location
                result += nested + item.prefix + String(expected)
                    + text.substring(with: NSRange(location: sibling.markerEnd - 1, length: NSMaxRange(lineRange) - sibling.markerEnd + 1))
                nested = ""
                end = NSMaxRange(lineRange)
                expected += 1
            } else if line.hasPrefix(item.prefix + " ") || line.hasPrefix(item.prefix + "\t") {
                nested += line  // a deeper line belongs to the item above
            } else {
                break
            }
            location = NSMaxRange(lineRange)
        }
        guard let start else { return nil }
        return (NSRange(location: start, length: end - start), result)
    }
}
