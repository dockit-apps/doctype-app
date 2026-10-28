// One table cell's text as the editor shows it, and back to markdown.
//
// In the note a cell is part of one line: a line break in it is written `<br>`
// and a "|" in its text `\|`. The editor shows a real line break and a plain
// "|", and every keystroke there is written back with `markdown(fromEditorText:)`.
// Offsets map both ways, so a cursor or selection in the markdown (a find
// match, an undo) can be shown in the editor, and the other way round.
// Alternative considered: editing the markdown as is, `<br>` and all; that's
// what the editor tried first, and a cell then can't show its line breaks.

import Foundation

public struct TableCellText: Equatable, Sendable {
    /// The cell's markdown, without the spaces around it.
    public let markdown: String
    /// What the editor shows.
    public let editorText: String
    /// For each editor offset (0 through its length, UTF-16), the markdown offset.
    private let markdownOffsets: [Int]

    public init(markdown: String) {
        let source = markdown as NSString
        let breaks = TableEditing.lineBreaks(in: NSRange(location: 0, length: source.length), of: source)
        var shown: [unichar] = []
        var offsets: [Int] = []
        var index = 0
        var nextBreak = 0
        while index < source.length {
            if nextBreak < breaks.count, breaks[nextBreak].location == index {
                shown.append(10)  // "\n"
                offsets.append(index)
                index = breaks[nextBreak].upperBound
                nextBreak += 1
            } else if source.character(at: index) == 92, index + 1 < source.length,
                      source.character(at: index + 1) == 124 {  // "\|"
                shown.append(124)
                offsets.append(index)
                index += 2
            } else {
                shown.append(source.character(at: index))
                offsets.append(index)
                index += 1
            }
            while nextBreak < breaks.count, breaks[nextBreak].location < index { nextBreak += 1 }
        }
        offsets.append(source.length)
        self.markdown = markdown
        self.editorText = String(utf16CodeUnits: shown, count: shown.count)
        self.markdownOffsets = offsets
    }

    /// The markdown offset of an editor offset.
    public func markdownOffset(forEditorOffset offset: Int) -> Int {
        markdownOffsets[min(max(offset, 0), markdownOffsets.count - 1)]
    }

    /// The editor offset of a markdown offset; one inside a `<br>` or `\|` maps
    /// to just before it.
    public func editorOffset(forMarkdownOffset offset: Int) -> Int {
        markdownOffsets.lastIndex { $0 <= offset } ?? 0
    }

    /// A markdown range shown in the editor.
    public func editorRange(forMarkdownRange range: NSRange) -> NSRange {
        let start = editorOffset(forMarkdownOffset: range.location)
        let end = range.length == 0 ? start : max(editorOffset(forMarkdownOffset: range.upperBound), start)
        // An end inside a `<br>` or `\|` includes it.
        let isInside = markdownOffset(forEditorOffset: end) < range.upperBound
        let adjustedEnd = isInside && end < markdownOffsets.count - 1 ? end + 1 : end
        return NSRange(location: start, length: adjustedEnd - start)
    }

    /// The markdown for what's in the editor: line breaks become `<br>`, and a
    /// "|" becomes `\|` (one already written `\|` stays as it is).
    public static func markdown(fromEditorText text: String) -> String {
        let source = text as NSString
        var result: [unichar] = []
        result.reserveCapacity(source.length)
        var index = 0
        while index < source.length {
            let character = source.character(at: index)
            switch character {
            case 13 where index + 1 < source.length && source.character(at: index + 1) == 10:  // "\r\n"
                result += Array("<br>".utf16)
                index += 1
            case 10, 13, 0x2028, 0x2029:  // line breaks
                result += Array("<br>".utf16)
            case 124 where index == 0 || source.character(at: index - 1) != 92:  // "|", not after "\"
                result += [92, 124]
            default:
                result.append(character)
            }
            index += 1
        }
        return String(utf16CodeUnits: result, count: result.count)
    }
}
