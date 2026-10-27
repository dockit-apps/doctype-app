// Tests for which ranges get which style. Spans are shown as (styled text, style).

import Foundation
import Testing
@testable import DocTypeCore

struct MarkdownStylerTests {
    private func styled(_ text: String) -> [(String, Style)] {
        let string = text as NSString
        return MarkdownStyler.spans(in: string, blocks: BlockMap(text: string).blocks)
            .map { (string.substring(with: $0.range), $0.style) }
    }

    private func expectSpans(_ text: String, _ expected: [(String, Style)], sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = styled(text)
        #expect(actual.map(\.0) == expected.map(\.0), sourceLocation: sourceLocation)
        #expect(actual.map(\.1) == expected.map(\.1), sourceLocation: sourceLocation)
    }

    @Test func atxHeadingWithDimmedHashes() {
        expectSpans("# Title\n\nbody", [("# Title", .heading(level: 1)), ("# ", .syntaxMarker)])
        expectSpans("### Deep ###", [("### Deep ###", .heading(level: 3)), ("### ", .syntaxMarker), (" ###", .syntaxMarker)])
    }

    @Test func headingWithTurkishAndEmojiCoversExactUTF16Range() {
        let text = "intro\n\n## Özet ğüşıç 🎓 notes\nafter"
        let spans = MarkdownStyler.spans(in: text as NSString, blocks: BlockMap(text: text as NSString).blocks)
        let heading = spans.first { $0.style == .heading(level: 2) }
        #expect(heading?.range == (text as NSString).range(of: "## Özet ğüşıç 🎓 notes"))
    }

    @Test func setextHeadingDimsUnderline() {
        expectSpans("Title\n=====\n", [("Title\n=====", .heading(level: 1)), ("=====", .syntaxMarker)])
    }

    @Test func fencedCodeIsMonospaceWithDimmedFences() {
        expectSpans("```swift\nlet a = 1\n```\n\n", [
            ("```swift\nlet a = 1\n```", .codeBlock), ("```swift", .syntaxMarker), ("```", .syntaxMarker),
        ])
    }

    @Test func unclosedFenceStylesToTheEnd() {
        expectSpans("```\ncode\nmore", [("```\ncode\nmore", .codeBlock), ("```", .syntaxMarker)])
    }

    @Test func blockquoteDimsEveryQuoteMarker() {
        expectSpans("> one\n> two", [("> one\n> two", .blockquote), ("> ", .syntaxMarker), ("> ", .syntaxMarker)])
    }

    @Test func thematicBreakIsDimmed() {
        expectSpans("para\n\n---\n", [("---", .syntaxMarker)])
    }

    @Test func dashesUnderAParagraphAreASetextHeadingNotARule() {
        #expect(styled("Title\n---\n").first?.1 == .heading(level: 2))
    }

    @Test func indentedCodeAfterParagraph() {
        expectSpans("para\n\n    code\n", [("    code", .codeBlock)])
    }

    @Test func spansUseDocumentPositionsForLaterBlocks() {
        let text = "first\n\n# Second" as NSString
        let spans = MarkdownStyler.spans(in: text, blocks: BlockMap(text: text).blocks)
        #expect(spans.first?.range == NSRange(location: 7, length: 8))
    }

    @Test func styleDocumentReturnsMapAndSpans() async {
        let result = await MarkdownStyler.styleDocument("# A\n\n```\nb\n```")
        #expect(result.blockMap.blocks.count == 2)
        #expect(result.spans.contains { $0.style == .codeBlock })
    }

    @Test func plainParagraphHasNoSpans() {
        #expect(styled("just some words\nacross lines").isEmpty)
    }
}

/// Simulates the editor: after each edit only the dirty range is restyled, and the
/// result must equal styling the whole document from scratch.
struct IncrementalStylingTests {
    private static let container = NSAttributedString.Key("container")
    private static let marker = NSAttributedString.Key("marker")

    /// Applies spans like EditorTheme would: container styles, then markers on top.
    private static func apply(_ spans: [StyleSpan], to text: NSMutableAttributedString, resetting range: NSRange) {
        text.setAttributes([:], range: range)
        for span in spans {
            let key = span.style == .syntaxMarker ? marker : container
            text.addAttribute(key, value: "\(span.style)", range: span.range)
        }
    }

    private static func fullyStyled(_ string: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: string)
        let map = BlockMap(text: result.mutableString)
        apply(MarkdownStyler.spans(in: result.mutableString, blocks: map.blocks), to: result,
              resetting: NSRange(location: 0, length: result.length))
        return result
    }

    @Test(arguments: [3, 99] as [UInt64])
    func restylingOnlyTheDirtyRangeMatchesFullStyling(seed: UInt64) {
        var random = SplitMix(seed: seed)
        let pieces = ["# ", "## Heading\n", "**", "\n", "\n\n", "```\n", "```swift\n", "> ", "---\n", "    ",
                      "text ", "===\n", "- [ ] ", "ğ", "🎓"]
        let document = NSMutableAttributedString(attributedString: Self.fullyStyled("# Start\n\nSome text.\n"))
        var map = BlockMap(text: document.mutableString)

        for step in 0..<1_500 {
            let text = document.mutableString
            var location = Int.random(in: 0...text.length, using: &random)
            if location < text.length { location = text.rangeOfComposedCharacterSequence(at: location).location }
            var deleteLength = 0
            if Bool.random(using: &random), location < text.length {
                let end = min(text.length, location + Int.random(in: 1...5, using: &random))
                deleteLength = (end < text.length ? text.rangeOfComposedCharacterSequence(at: end).location : end) - location
            }
            let insert = deleteLength > 0 ? "" : pieces.randomElement(using: &random)!
            document.replaceCharacters(in: NSRange(location: location, length: deleteLength), with: insert)

            let inserted = (insert as NSString).length
            let dirty = map.update(text: document.mutableString,
                                   editedRange: NSRange(location: location, length: inserted),
                                   changeInLength: inserted - deleteLength)
            let spans = MarkdownStyler.spans(in: document.mutableString, blocks: map.blocks(in: dirty))
            Self.apply(spans, to: document, resetting: dirty)

            let expected = Self.fullyStyled(document.string)
            guard document.isEqual(to: expected) else {
                Issue.record("Styles diverged at step \(step) after inserting \(insert.debugDescription) at \(location)")
                return
            }
        }
    }
}
