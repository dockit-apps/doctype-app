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

    @Test func fencedCodeIsMonospaceHighlightedWithDimmedFences() {
        expectSpans("```swift\nlet a = 1\n```\n\n", [
            ("```swift\nlet a = 1\n```", .codeBlock), ("let", .code(.keyword)), ("1", .code(.number)),
            ("```swift\n", .syntaxMarker), ("```\n", .syntaxMarker),
        ])
    }

    @Test func unclosedFenceStylesToTheEnd() {
        expectSpans("```\ncode\nmore", [("```\ncode\nmore", .codeBlock), ("```\n", .syntaxMarker)])
    }

    @Test func blockquoteDimsEveryQuoteMarker() {
        expectSpans("> one\n> two", [("> one\n> two", .blockquote), ("> ", .syntaxMarker), ("> ", .syntaxMarker)])
    }

    @Test func thematicBreakIsARuleWithAMarker() {
        expectSpans("para\n\n---\n", [("---", .horizontalRule), ("---", .syntaxMarker)])
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

    // MARK: Reveal ranges (markers hide unless the cursor is there)

    private func markers(_ text: String) -> [(marker: String, revealedBy: String)] {
        let string = text as NSString
        return MarkdownStyler.spans(in: string, blocks: BlockMap(text: string).blocks)
            .filter { $0.style == .syntaxMarker }
            .map { (string.substring(with: $0.range), string.substring(with: $0.revealRange!)) }
    }

    @Test func headingAndQuoteMarkersRevealOnTheirOwnLine() {
        let result = markers("# Title\nmore\n\n> one\n> two")
        #expect(result.map(\.revealedBy) == ["# Title", "> one", "> two"])
    }

    @Test func fencesRevealAnywhereInTheirCodeBlock() {
        let result = markers("```swift\nlet a = 1\n```\n\nafter")
        #expect(result.map(\.revealedBy) == ["```swift\nlet a = 1\n```", "```swift\nlet a = 1\n```"])
    }

    @Test func setextUnderlineRevealsOnEitherLineOfTheHeading() {
        #expect(markers("Title\n=====\n").map(\.revealedBy) == ["Title\n====="])
    }

    @Test func revealCheckCountsTouchingTheEdges() {
        let span = StyleSpan(NSRange(location: 0, length: 2), .syntaxMarker, revealRange: NSRange(location: 0, length: 7))
        #expect(span.isRevealed(by: NSRange(location: 7, length: 0)))   // cursor at line end
        #expect(!span.isRevealed(by: NSRange(location: 8, length: 0)))  // next line
        #expect(span.isRevealed(by: NSRange(location: 8, length: 0)) == false)
        #expect(span.isRevealed(by: NSRange(location: 3, length: 20)))  // selection across
        #expect(StyleSpan(NSRange(location: 0, length: 1), .heading(level: 1)).isRevealed(by: NSRange(location: 99, length: 0)))
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

/// Constructs format only once a space follows their syntax (or, for `---` and
/// setext underlines, once the cursor leaves the line).
struct ConfirmationTests {
    private func spans(_ text: String) -> [StyleSpan] {
        let string = text as NSString
        return MarkdownStyler.spans(in: string, blocks: BlockMap(text: string).blocks)
    }

    @Test(arguments: [">", ">text", "  >", ">\nnext"])
    func quoteWithoutSpaceStaysPlain(text: String) {
        #expect(!spans(text).contains { $0.style == .blockquote }, "\(text.debugDescription) became a quote")
    }

    @Test(arguments: ["> ", "> text", ">\ttext", "> one\n> two"])
    func quoteWithSpaceIsAQuote(text: String) {
        #expect(spans(text).contains { $0.style == .blockquote }, "\(text.debugDescription) didn't become a quote")
    }

    @Test func quoteMarkerIncludesTheSpaceSoTextStartsCleanly() {
        let text = "> text" as NSString
        let marker = spans(text as String).first { $0.style == .syntaxMarker }
        #expect(marker.map { text.substring(with: $0.range) } == "> ")
    }

    @Test func ruleWithoutTrailingSpaceIsHeldBackOnlyOnItsLine() {
        let text = "para\n\n---\n\nafter" as NSString
        let rule = spans(text as String).first { $0.style == .horizontalRule }
        #expect(rule?.unconfirmedRange == text.range(of: "---"))
        #expect(rule?.isHeldBack(by: NSRange(location: 9, length: 0)) == true)    // cursor right after "---"
        #expect(rule?.isHeldBack(by: NSRange(location: 13, length: 0)) == false)  // cursor on "after"
    }

    @Test func ruleWithTrailingSpaceIsConfirmed() {
        let all = spans("para\n\n--- \n")
        #expect(all.contains { $0.style == .horizontalRule && $0.unconfirmedRange == nil })
        #expect(all.filter { $0.style == .syntaxMarker }.allSatisfy { $0.unconfirmedRange == nil })
    }

    @Test func setextUnderlineIsHeldBackWhileTypingIt() {
        let text = "Title\n-" as NSString
        let heading = spans(text as String).first { $0.style == .heading(level: 2) }
        #expect(heading?.unconfirmedRange == NSRange(location: 6, length: 1))
        #expect(heading?.isHeldBack(by: NSRange(location: 7, length: 0)) == true)
        #expect(heading?.isHeldBack(by: NSRange(location: 2, length: 0)) == false)  // cursor on the title line
    }

    @Test func atxHeadingsNeedNoConfirmation() {
        // "# " already needs a space in markdown itself.
        #expect(spans("# Title").allSatisfy { $0.unconfirmedRange == nil })
        #expect(!spans("#Title").contains { $0.style == .heading(level: 1) })
    }
}
