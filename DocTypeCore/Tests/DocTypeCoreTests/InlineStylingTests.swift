// Tests for inline styles, list and task markers, and tables.
// Spans are shown as (styled text, style), in the order they're applied.

import Foundation
import Testing
@testable import DocTypeCore

struct InlineStylingTests {
    private func styled(_ text: String) -> [(String, Style)] {
        let string = text as NSString
        return MarkdownStyler.spans(in: string, blocks: BlockMap(text: string).blocks)
            .map { (string.substring(with: $0.range), $0.style) }
    }

    private func has(_ text: String, _ piece: String, _ style: Style) -> Bool {
        styled(text).contains { $0 == (piece, style) }
    }

    @Test func boldItalicStrikethroughAndCode() {
        let text = "a **bold** _it_ ~~gone~~ `code` z"
        #expect(has(text, "**bold**", .strong))
        #expect(has(text, "_it_", .emphasis))
        #expect(has(text, "~~gone~~", .strikethrough))
        #expect(has(text, "`code`", .inlineCode))
        let markers = styled(text).filter { $0.1 == .syntaxMarker }.map(\.0)
        #expect(markers == ["**", "**", "_", "_", "~~", "~~", "`", "`"])
    }

    @Test func nestedBoldItalicGetsBothStyles() {
        let text = "***both***"
        #expect(styled(text).contains { $0.1 == .strong })
        #expect(styled(text).contains { $0.1 == .emphasis })
        #expect(has("**bold `code`**", "`code`", .inlineCode))
    }

    @Test func inlineStylesInsideHeadingsAreApplied() {
        #expect(has("## Steps with `bfs()`", "`bfs()`", .inlineCode))
        #expect(has("# A **bold** title", "**bold**", .strong))
    }

    @Test func unclosedAndEscapedMarkersStayPlain() {
        #expect(styled("**abc").isEmpty)
        #expect(styled(#"\*not italic\*"#).isEmpty)
    }

    @Test func doubleBacktickCodeHasTwoCharacterMarkers() {
        #expect(styled("``a`b``").filter { $0.1 == .syntaxMarker }.map(\.0) == ["``", "``"])
    }

    @Test func linkTextIsStyledAndURLSyntaxIsAMarker() {
        let text = "see [the docs](https://example.com \"Title\") now"
        #expect(has(text, "the docs", .link(destination: "https://example.com")))
        #expect(styled(text).filter { $0.1 == .syntaxMarker }.map(\.0) == ["[", "](https://example.com \"Title\")"])
        #expect(has("[notes](../Uni/Graphs.md)", "notes", .link(destination: "../Uni/Graphs.md")))
    }

    @Test func angleBracketAutolinksAreLinks() {
        #expect(has("<https://example.com>", "https://example.com", .link(destination: "https://example.com")))
    }

    private func bareLinks(_ text: String) -> [String] {
        styled(text).compactMap { if case .link(let destination) = $0.1 { "\($0.0) → \(destination)" } else { nil } }
    }

    @Test func bareURLsAreLinks() {
        #expect(bareLinks("visit https://example.com/a?b=1 today") == ["https://example.com/a?b=1 → https://example.com/a?b=1"])
        #expect(bareLinks("or www.apple.com.") == ["www.apple.com → https://www.apple.com"])
        #expect(bareLinks("(see http://x.org/wiki/Graph_(math)), ok") == ["http://x.org/wiki/Graph_(math) → http://x.org/wiki/Graph_(math)"])
        #expect(bareLinks("**https://bold.dev**") == ["https://bold.dev → https://bold.dev"])
    }

    @Test func thingsThatAreNotBareURLs() {
        #expect(bareLinks("myhttps://x.org and http:// and www. alone").isEmpty)
        #expect(bareLinks("`https://in.code` and\n\n    https://indented.code").isEmpty)
        #expect(bareLinks("[label](https://a.org) <https://b.org>").count == 2)  // not linked twice
    }

    @Test func inlineMarkersRevealOnTheirLine() {
        let text = "one **b**\ntwo" as NSString
        let marker = MarkdownStyler.spans(in: text, blocks: BlockMap(text: text).blocks).first { $0.style == .syntaxMarker }
        #expect(marker?.revealRange == NSRange(location: 0, length: 9))
    }

    // MARK: Lists and tasks

    @Test func bulletsAndNumbers() {
        #expect(has("- item", "-", .listBullet))
        #expect(has("* item", "*", .listBullet))
        #expect(has("  - nested", "-", .listBullet))
        #expect(has("1. first", "1.", .listNumber))
        #expect(has("12) twelfth", "12)", .listNumber))
    }

    @Test(arguments: ["-", "1.", "-\nnext"])
    func markerWithoutSpaceStaysPlain(text: String) {
        #expect(!styled(text).contains { $0.1 == .listBullet || $0.1 == .listNumber })
    }

    @Test func tasksHideTheBulletAndDrawABox() {
        let open = styled("- [ ] buy milk")
        #expect(open.contains { $0 == ("- ", .hiddenMarker) })
        #expect(open.contains { $0 == ("[ ]", .taskBox(checked: false)) })
        #expect(!open.contains { $0.1 == .completedTask })

        let done = styled("- [x] buy milk")
        #expect(done.contains { $0 == ("[x]", .taskBox(checked: true)) })
        #expect(done.contains { $0 == ("buy milk", .completedTask) })
    }

    @Test func checkboxNeedsASpaceAfterIt() {
        #expect(!styled("- [ ]").contains { if case .taskBox = $0.1 { true } else { false } })
    }

    @Test func numberedTasksWork() {
        #expect(has("1. [x] done", "[x]", .taskBox(checked: true)))
    }

    // MARK: Tables

    @Test func tableRowsPipesAndTheDelimiterRow() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |" as NSString
        let spans = MarkdownStyler.spans(in: text, blocks: BlockMap(text: text).blocks)
        #expect(spans.filter { $0.style == .tablePipe }.count == 9)
        let rows = spans.compactMap { span -> String? in
            guard case .tableRow(let index, let isLast) = span.style else { return nil }
            #expect(span.revealRange == NSRange(location: 0, length: text.length))  // the whole table
            return "\(index)\(isLast ? "!" : ""):\(text.substring(with: span.range))"
        }
        #expect(rows == ["0:| a | b |", "1:|---|---|", "2!:| 1 | 2 |"])
        // The delimiter row is syntax, shown only while the cursor is on it.
        let delimiter = spans.first { $0.style == .syntaxMarker }
        #expect(delimiter.map { text.substring(with: $0.range) } == "|---|---|")
        #expect(delimiter?.revealRange == NSRange(location: 10, length: 9))
    }

    private func cells(_ text: String) -> [String] {
        styled(text).compactMap { piece, style in
            guard case .tableCell(_, let column, let alignment) = style else { return nil }
            return "\(column)\(alignment == .left ? "L" : alignment == .right ? "R" : "C"):\(piece)"
        }
    }

    @Test func everyCellIsMarkedWithItsColumnAndAlignment() {
        #expect(cells("| a | bb |\n|:--|--:|\n| 1 | 2 |") ==
                ["0L: a ", "1R: bb ", "0L::--", "1R:--:", "0L: 1 ", "1R: 2 "])
        #expect(cells("a | b\n:-:|-\nx|") == ["0C:a ", "1L: b", "0C::-:", "1L:-", "0C:x"])
    }

    @Test func escapedPipesAndEmptyCells() {
        #expect(cells("| a \\| b | c |\n|---|---|\n|| z |") ==
                ["0L: a \\| b ", "1L: c ", "0L:---", "1L:---", "0L:", "1L: z "])
    }

    /// cmark-gfm starts a table right under a paragraph at the paragraph's
    /// first line; the paragraph must not become the header row.
    @Test func tableRightAfterAParagraphStartsAtItsHeader() {
        let text = "text\n| a | b |\n|---|---|\n| 1 | 2 |" as NSString
        let rows = MarkdownStyler.spans(in: text, blocks: BlockMap(text: text).blocks).compactMap { span -> String? in
            guard case .tableRow(let index, _) = span.style else { return nil }
            #expect(span.revealRange == NSRange(location: 5, length: text.length - 5))
            return "\(index):\(text.substring(with: span.range))"
        }
        #expect(rows == ["0:| a | b |", "1:|---|---|", "2:| 1 | 2 |"])
        #expect(!has(text as String, "text", .strong))
    }

    @Test func headerRowIsBold() {
        #expect(has("| Name | Grade |\n|---|---|\n| Al | 1 |", " Name ", .strong))
        #expect(!has("| Name | Grade |\n|---|---|\n| Al | 1 |", " Al ", .strong))
    }
}

/// cmark-gfm can report a table cell column that falls inside a multi-byte
/// character; styling must not crash (found by the incremental property test).
@Test func tableWithMultiByteCharactersDoesNotCrash() {
    let text = " `| a> | b|- ## | a | b \n|--- [x] -|---|\nHeading\nx]- ] ğ\n-- tex###  H `~~#-     --|\n`|b [ ] \n---`\n__t`enk`ğ*~-\n--|``\n\n" as NSString
    let spans = MarkdownStyler.spans(in: text, blocks: BlockMap(text: text).blocks)
    #expect(spans.allSatisfy { NSMaxRange($0.range) <= text.length })
}
