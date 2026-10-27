// Tests for code-block syntax highlighting. Tokens are shown as (text, kind).

import Foundation
import Testing
@testable import DocTypeCore

struct CodeHighlighterTests {
    private func tokens(_ code: String, _ language: String) -> [(String, CodeToken)] {
        let text = code as NSString
        return CodeHighlighter.spans(in: text, range: NSRange(location: 0, length: text.length), language: language)
            .compactMap { span in
                guard case .code(let token) = span.style else { return nil }
                return (text.substring(with: span.range), token)
            }
    }

    private func expectTokens(_ code: String, _ language: String, _ expected: [(String, CodeToken)],
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = tokens(code, language)
        #expect(actual.map(\.0) == expected.map(\.0), sourceLocation: sourceLocation)
        #expect(actual.map(\.1) == expected.map(\.1), sourceLocation: sourceLocation)
    }

    @Test func swiftKeywordsTypesStringsNumbersComments() {
        expectTokens("let name: String = \"hi\" // greet\nreturn 42", "swift", [
            ("let", .keyword), ("String", .type), ("\"hi\"", .string), ("// greet", .comment),
            ("return", .keyword), ("42", .number),
        ])
    }

    @Test func blockCommentsAndMultiLineStringsSpanLines() {
        expectTokens("/* a\nb */ x", "c", [("/* a\nb */", .comment)])
        expectTokens("s = \"\"\"\nline\n\"\"\"", "python", [("\"\"\"\nline\n\"\"\"", .string)])
    }

    @Test func escapedQuotesStayInsideTheString() {
        expectTokens(#"x = "a\"b" + 1"#, "javascript", [(#""a\"b""#, .string), ("1", .number)])
    }

    @Test func singleQuoteStringsEndAtLineEnd() {
        // An unterminated string must not swallow the rest of the block.
        expectTokens("x = 'oops\ny = 2", "python", [("'oops", .string), ("2", .number)])
    }

    @Test func pythonDoesNotTreatCapitalizedNamesAsTypesButKnowsTrue() {
        expectTokens("if Value is True: pass", "py", [("if", .keyword), ("is", .keyword), ("True", .keyword), ("pass", .keyword)])
    }

    @Test func sqlKeywordsAreCaseInsensitive() {
        expectTokens("SELECT name FROM users -- all", "sql", [
            ("SELECT", .keyword), ("FROM", .keyword), ("-- all", .comment),
        ])
    }

    @Test func identifiersContainingDigitsAreNotNumbers() {
        expectTokens("int x1 = 2;", "c", [("int", .keyword), ("2", .number)])
    }

    @Test func aliasesAndInfoStringExtrasWork() {
        #expect(!tokens("let a = 1", "Swift title=\"Example\"").isEmpty)
        #expect(!tokens("echo hi", "sh").isEmpty)
    }

    @Test func unknownLanguageGetsNoTokens() {
        #expect(tokens("let a = 1", "").isEmpty)
        #expect(tokens("let a = 1", "brainfuck").isEmpty)
    }

    @Test func fencedBlockInNoteIsHighlightedButFencesStayMarkers() {
        let text = "```swift\nlet a = 1\n```" as NSString
        let spans = MarkdownStyler.spans(in: text, blocks: BlockMap(text: text).blocks)
        let styles = spans.map { (text.substring(with: $0.range), $0.style) }
        #expect(styles.contains { $0 == ("let", .code(.keyword)) })
        #expect(styles.contains { $0 == ("```swift\n", .syntaxMarker) })
        #expect(!styles.contains { $0.0 == "swift" && $0.1 == .code(.keyword) })  // the info string isn't code
    }
}
