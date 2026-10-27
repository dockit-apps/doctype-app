// Converts swift-markdown source locations to UTF-16 offsets.
//
// swift-markdown reports (line, column) with 1-based lines and columns counted in
// UTF-8 bytes, while NSTextStorage counts UTF-16 units. In "# Özet" the "z" is
// at UTF-8 column 5 but UTF-16 offset 3, so every range needs converting.

import Foundation
import Markdown

struct SourceMapping {
    private let text: String
    /// Start index of each line (line 1 is element 0) and its UTF-16 offset.
    private var lineStarts: [(index: String.Index, utf16Offset: Int)] = []

    init(_ text: String) {
        self.text = text
        var utf16Offset = 0
        var lineStart = text.startIndex
        lineStarts.append((lineStart, 0))
        var index = text.utf8.startIndex
        // Line breaks as cmark sees them: \n, \r\n or a lone \r.
        while index < text.utf8.endIndex {
            let byte = text.utf8[index]
            var next = text.utf8.index(after: index)
            if byte == UInt8(ascii: "\r"), next < text.utf8.endIndex, text.utf8[next] == UInt8(ascii: "\n") {
                next = text.utf8.index(after: next)
            }
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                utf16Offset += text.utf16.distance(from: lineStart, to: next)
                lineStart = next
                lineStarts.append((lineStart, utf16Offset))
            }
            index = next
        }
    }

    /// UTF-16 offset of a source location, clamped to the text.
    func utf16Offset(of location: SourceLocation) -> Int {
        let line = min(max(location.line - 1, 0), lineStarts.count - 1)
        let start = lineStarts[line]
        let utf8 = text.utf8
        let target = utf8.index(start.index, offsetBy: location.column - 1, limitedBy: utf8.endIndex) ?? utf8.endIndex
        return start.utf16Offset + text.utf16.distance(from: start.index, to: target)
    }

    /// UTF-16 range for a source range, shifted by `base` (the block's position in the document).
    func range(of sourceRange: SourceRange, base: Int) -> NSRange {
        let lower = utf16Offset(of: sourceRange.lowerBound)
        let upper = utf16Offset(of: sourceRange.upperBound)
        return NSRange(location: base + lower, length: max(upper - lower, 0))
    }
}
