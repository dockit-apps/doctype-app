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
        #expect(has(text, "the docs", .link))
        #expect(styled(text).filter { $0.1 == .syntaxMarker }.map(\.0) == ["[", "](https://example.com \"Title\")"])
    }

    @Test func angleBracketAutolinksAreLinks() {
        #expect(has("<https://example.com>", "https://example.com", .link))
    }

    /// swift-markdown doesn't enable GFM's bare-URL autolink extension, so the editor
    /// (and the preview, which uses the same parser) leave bare URLs as text for now.
    @Test func bareURLsAreNotLinkedYet() {
        #expect(!styled("visit https://example.com today").contains { $0.1 == .link })
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

    @Test func tablePipesAreDimmedButAlwaysVisible() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |" as NSString
        let spans = MarkdownStyler.spans(in: text, blocks: BlockMap(text: text).blocks)
        let markers = spans.filter { $0.style == .syntaxMarker }
        #expect(markers.count == 7)  // 3 + delimiter row + 3
        #expect(markers.allSatisfy { $0.revealRange == nil })
    }
}

/// cmark-gfm can report a table cell column that falls inside a multi-byte
/// character; styling must not crash (found by the incremental property test).
@Test func tableWithMultiByteCharactersDoesNotCrash() {
    let text = " `| a> | b|- ## | a | b \n|--- [x] -|---|\nHeading\nx]- ] ğ\n-- tex###  H `~~#-     --|\n`|b [ ] \n---`\n__t`enk`ğ*~-\n--|``\n\n" as NSString
    let spans = MarkdownStyler.spans(in: text, blocks: BlockMap(text: text).blocks)
    #expect(spans.allSatisfy { NSMaxRange($0.range) <= text.length })
}
