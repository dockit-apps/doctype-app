// Tests for image spans, the "alt|300" width syntax, and the resize edit.
// Selections are marked with "|" in the text after an edit.

import Foundation
import Testing
@testable import DocTypeCore

struct ImageSizingTests {
    @Test func widthIsReadFromTheAltText() {
        #expect(ImageSizing.parse(alt: "Graph|300") == ("Graph", 300))
        #expect(ImageSizing.parse(alt: "Graph | 300x200") == ("Graph", 300))
        #expect(ImageSizing.parse(alt: "|120") == ("", 120))
        #expect(ImageSizing.parse(alt: "a|b") == ("a|b", nil))
        #expect(ImageSizing.parse(alt: "plain") == ("plain", nil))
        #expect(ImageSizing.parse(alt: "zero|0") == ("zero|0", nil))
    }

    private func images(_ text: String) -> [String] {
        let string = text as NSString
        return MarkdownStyler.spans(in: string, blocks: BlockMap(text: string).blocks).compactMap { span in
            guard case .image(let source, let width) = span.style else { return nil }
            return "\(string.substring(with: span.range)) → \(source) \(width.map(String.init) ?? "-")"
        }
    }

    @Test func imagesGetOneSpanForTheirWholeSyntax() {
        #expect(images("see ![Graph|300](img/graph.png \"t\") here") == ["![Graph|300](img/graph.png \"t\") → img/graph.png 300"])
        #expect(images("![](a%20b.png)") == ["![](a%20b.png) → a%20b.png -"])
        #expect(images("`![x](y.png)`").isEmpty)
    }

    @Test func imageSyntaxShowsOnItsLineOnly() {
        let text = "intro\n![a](b.png)\nnext" as NSString
        let span = MarkdownStyler.spans(in: text, blocks: BlockMap(text: text).blocks).first {
            if case .image = $0.style { true } else { false }
        }
        #expect(span?.revealRange == NSRange(location: 6, length: 11))
    }

    private func resize(_ text: String, to width: Int, cursor: Int = 0) -> String? {
        let string = text as NSString
        let range = string.range(of: "![")
        let end = string.range(of: ")", range: NSRange(location: range.location, length: string.length - range.location))
        let image = NSRange(location: range.location, length: end.upperBound - range.location)
        guard let edit = ImageSizing.edit(settingWidth: width, forImageAt: image, in: string,
                                          selection: NSRange(location: cursor, length: 0)) else { return nil }
        return (edit.applied(to: text) as NSString).replacingCharacters(in: edit.selectionAfter, with: "|")
    }

    @Test func resizingWritesTheWidthIntoTheAltText() {
        #expect(resize("![Graph](g.png)", to: 300) == "|![Graph|300](g.png)")
        #expect(resize("![Graph|120](g.png)", to: 300) == "|![Graph|300](g.png)")
        #expect(resize("![](g.png)", to: 250) == "|![|250](g.png)")
        #expect(resize("![a [b] c](g.png)", to: 90) == "|![a [b] c|90](g.png)")
        #expect(resize("![x](g.png)", to: 5) == "|![x|32](g.png)")  // never smaller than the minimum
    }

    @Test func resizingKeepsTheCursorOnItsCharacter() {
        #expect(resize("![Graph](g.png) after", to: 300, cursor: 16) == "![Graph|300](g.png) |after")
    }

    @Test func snippetsLeaveOutTheWidth() {
        #expect(NoteSummary.make(path: "N.md", text: "![Graph|300](g.png) text", modified: .now).snippet == "Graph text")
    }
}
