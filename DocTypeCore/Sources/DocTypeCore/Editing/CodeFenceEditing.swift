// Return at the end of an opening code fence ("```swift") that isn't closed yet
// adds the closing fence below and puts the cursor on the empty line between.
//
// Why: an unclosed fence turns the rest of the note into code until it's closed,
// which restyles everything below on every keystroke and looks broken while
// typing. Closing it right away keeps the note intact.
// A fence that already has a closing fence below (re-typing over an existing
// block) gets a plain Return.

import Foundation

public enum CodeFenceEditing {
    private static let openingFence = try! NSRegularExpression(pattern: "^( {0,3})(`{3,}|~{3,})(.*)$")

    /// What Return should do at `selection`, or nil to leave it to the next rule.
    public static func editForNewline(in text: NSString, selection: NSRange, blockMap: BlockMap) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        guard selection.location == contentsEnd else { return nil }
        let line = text.substring(with: NSRange(location: start, length: contentsEnd - start)) as NSString
        guard let match = openingFence.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))
        else { return nil }
        let indent = line.substring(with: match.range(at: 1))
        let fence = line.substring(with: match.range(at: 2))
        if fence.hasPrefix("`"), line.substring(with: match.range(at: 3)).contains("`") { return nil }  // not a fence

        // It must open a code block (not close one), and that block must be unclosed.
        guard let block = blockMap.blocks(in: NSRange(location: start, length: 0)).first,
              case .code = block.kind, block.range.location == start,
              !hasClosingFence(fence, in: block, after: NSMaxRange(match.range) + start, text: text) else { return nil }

        let inserted = "\n" + indent + "\n" + indent + fence
        return TextEdit(range: selection, replacement: inserted,
                        selectionAfter: NSRange(location: selection.location + 1 + (indent as NSString).length, length: 0))
    }

    /// True if a line in `block` after `location` closes `fence` (same character,
    /// at least as long, nothing after it).
    private static func hasClosingFence(_ fence: String, in block: Block, after location: Int, text: NSString) -> Bool {
        let character = NSRegularExpression.escapedPattern(for: String(fence.first!))
        let closing = try! NSRegularExpression(pattern: "^ {0,3}\(character){\(fence.count),}[ \\t]*$",
                                               options: .anchorsMatchLines)
        let rest = text.substring(with: NSRange(location: location, length: NSMaxRange(block.range) - location))
        return closing.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) != nil
    }
}
