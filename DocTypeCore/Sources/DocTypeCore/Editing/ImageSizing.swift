// An image's display width, stored in the markdown itself so it survives in git,
// other editors and the MCP server: `![Graph|300](graph.png)` shows the image
// 300 points wide.
//
// Why this syntax: it's Obsidian's, and it keeps a valid CommonMark image, so
// every other renderer still shows the picture (with "Graph|300" as alt text,
// which is normally invisible). Alternatives considered: `<img width="300">`
// (HTML; the editor would need an HTML parser, and the note stops being plain
// markdown), Pandoc's `![](x.png){width=300}` (shows up as literal text on
// GitHub), and markdown-it's `![](x.png =300x)` (not CommonMark: the image
// stops being an image everywhere else).
// "|300x200" is accepted too; the height is ignored, the aspect ratio wins.

import Foundation
import Markdown

public enum ImageSizing {
    /// Smallest width resizing allows, so an image can't vanish.
    public static let minimumWidth = 32

    /// Splits alt text like "Graph|300" into the alt ("Graph") and the width (300).
    public static func parse(alt: String) -> (alt: String, width: Int?) {
        guard let bar = alt.lastIndex(of: "|") else { return (alt, nil) }
        let size = alt[alt.index(after: bar)...].trimmingCharacters(in: .whitespaces)
        let widthPart = size.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let width = Int(widthPart), width > 0, size.allSatisfy({ $0.isNumber || $0 == "x" }) else {
            return (alt, nil)
        }
        return (String(alt[..<bar]).trimmingCharacters(in: .whitespaces), width)
    }

    /// Rewrites the image syntax at `range` (`![alt](source)`) to show it `width`
    /// points wide: "alt" becomes "alt|width", or an existing width is replaced.
    /// The cursor stays where it was. Nil if there's no image at `range`.
    public static func edit(settingWidth width: Int, forImageAt range: NSRange, in text: NSString,
                            selection: NSRange) -> TextEdit? {
        guard range.location >= 0, NSMaxRange(range) <= text.length, range.length >= 4,
              text.substring(with: NSRange(location: range.location, length: 2)) == "![" else { return nil }
        let syntax = text.substring(with: range)
        guard let image = Document(parsing: syntax).child(through: [0, 0]) as? Image else { return nil }

        // The alt text runs from after "![" to its closing "]": the end of the last child.
        let mapping = SourceMapping(syntax)
        let altEnd = Array(image.children).last?.range.map { mapping.range(of: $0, base: 0).upperBound } ?? 2
        let altRange = NSRange(location: range.location + 2, length: altEnd - 2)
        let (alt, _) = parse(alt: text.substring(with: altRange))
        let replacement = "\(alt)|\(max(width, minimumWidth))"
        let newLength = (replacement as NSString).length
        // Keep the cursor on the same character: move it only if it's after the alt text.
        var after = selection
        if selection.location >= altRange.upperBound { after.location += newLength - altRange.length }
        return TextEdit(range: altRange, replacement: replacement, selectionAfter: after)
    }
}
