// Tests for splitting text into blocks, and for keeping the map correct while editing.

import Foundation
import Testing
@testable import DocTypeCore

struct BlockMapTests {
    /// Each block as (text, kind) for readable expectations.
    private func blocks(_ text: String) -> [(String, Block.Kind)] {
        let string = text as NSString
        return BlockMap(text: string).blocks.map { (string.substring(with: $0.range), $0.kind) }
    }

    private func texts(_ text: String) -> [String] { blocks(text).map(\.0) }

    @Test func paragraphsAreSeparatedByBlankLines() {
        #expect(texts("one\ntwo\n\nthree\n") == ["one\ntwo\n\n", "three\n"])
    }

    @Test func blocksCoverTheWholeText() {
        let text = "\n\n# Title\n\npara\n\n\n```\ncode\n```\n\nend"
        #expect(texts(text).joined() == text)
    }

    @Test func fencedCodeKeepsBlankLinesAndKnowsItsLanguage() {
        let result = blocks("intro\n\n```swift\nlet a = 1\n\nlet b = 2\n```\nafter\n")
        #expect(result.map(\.0) == ["intro\n\n", "```swift\nlet a = 1\n\nlet b = 2\n```\n", "after\n"])
        #expect(result[1].1 == .code(language: "swift"))
        #expect(result[2].1 == .text)
    }

    @Test func fenceInterruptsAParagraph() {
        #expect(texts("text\n~~~\ncode\n~~~\n") == ["text\n", "~~~\ncode\n~~~\n"])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        let result = blocks("a\n\n```\ncode\n\nmore text\n")
        #expect(result.last?.0 == "```\ncode\n\nmore text\n")
        #expect(result.last?.1 == .code(language: ""))
    }

    @Test func closingFenceMustMatchCharacterAndLength() {
        #expect(texts("````\n```\n~~~~\n````\nafter") == ["````\n```\n~~~~\n````\n", "after"])
    }

    @Test func inlineTripleBackticksAreNotAFence() {
        #expect(blocks("```code``` here\nmore").map(\.1) == [.text])
    }

    @Test func indentedLineAfterBlankLineContinuesTheBlock() {
        #expect(texts("- item\n\n  more of item\n\nnext") == ["- item\n\n  more of item\n\n", "next"])
    }

    @Test func indentedFenceInsideListIsStillAFence() {
        #expect(blocks("- item\n  ```\n  code\n  ```\n").map(\.1) == [.text, .code(language: "")])
    }

    @Test func crlfLineEndings() {
        #expect(texts("one\r\n\r\ntwo\r\n") == ["one\r\n\r\n", "two\r\n"])
    }

    @Test func emptyText() {
        #expect(BlockMap(text: "").blocks.isEmpty)
    }

    @Test func blocksInRange() {
        let text = "a\n\nb\n\nc\n" as NSString
        let map = BlockMap(text: text)
        #expect(map.blocks(in: NSRange(location: 3, length: 0)).map { text.substring(with: $0.range) } == ["b\n\n"])
        #expect(map.blocks(in: NSRange(location: 0, length: text.length)).count == 3)
    }
}

struct BlockMapIncrementalTests {
    /// Applies an edit like NSTextStorage does and checks the map against a fresh build.
    @discardableResult
    private func edit(_ text: NSMutableString, _ map: inout BlockMap, replacing range: NSRange, with insert: String) -> NSRange {
        text.replaceCharacters(in: range, with: insert)
        let inserted = (insert as NSString).length
        let dirty = map.update(
            text: text, editedRange: NSRange(location: range.location, length: inserted),
            changeInLength: inserted - range.length
        )
        #expect(map == BlockMap(text: text), "Incremental map differs after inserting \(insert.debugDescription) at \(range)")
        return dirty
    }

    @Test func typingInAParagraphOnlyDirtiesNearbyBlocks() {
        let text = NSMutableString(string: "one\n\ntwo\n\nthree\n\nfour\n")
        var map = BlockMap(text: text)

        let dirty = edit(text, &map, replacing: NSRange(location: 6, length: 0), with: "X")  // in "two"

        #expect(dirty == NSRange(location: 0, length: 11))  // "one" and "Xtwo", not "three"/"four"
    }

    @Test func openingAFenceDirtiesToTheEndAndClosingItRestores() {
        let text = NSMutableString(string: "a\n\nb\n\nc\n\nd\n")
        var map = BlockMap(text: text)

        let opened = edit(text, &map, replacing: NSRange(location: 3, length: 0), with: "```\n")
        #expect(opened.upperBound == text.length)

        edit(text, &map, replacing: NSRange(location: 9, length: 0), with: "```\n")
        #expect(map.blocks.map(\.kind).contains(.text))
    }

    @Test func deletingTheBlankLineMergesBlocks() {
        let text = NSMutableString(string: "one\n\ntwo\n")
        var map = BlockMap(text: text)
        edit(text, &map, replacing: NSRange(location: 3, length: 1), with: "")
        #expect(map.blocks.count == 1)
    }

    /// Property test: thousands of random edits, each checked against a fresh build.
    @Test(arguments: [7, 42, 2026] as [UInt64])
    func randomEditsMatchFullRebuild(seed: UInt64) {
        var random = SplitMix(seed: seed)
        let pieces = ["a", "word ", "\n", "\n\n", "```", "```swift\n", "~~~\n", "    ", "  ", "# ", "- [ ] ",
                      "> ", "\r\n", "ü", "🎓", "````\n", "\t"]
        let start = """
            # Title

            Paragraph one
            continues here.

            ```swift
            let x = 1

            let y = 2
            ```

            - item
              ```
              nested
              ```

            > quote
            """
        let text = NSMutableString(string: start)
        var map = BlockMap(text: text)

        for _ in 0..<3_000 {
            let location = snapped(Int.random(in: 0...text.length, using: &random), in: text)
            if Bool.random(using: &random), text.length > 0 {
                // Delete a small range.
                let end = snapped(min(text.length, location + Int.random(in: 1...6, using: &random)), in: text)
                edit(text, &map, replacing: NSRange(location: location, length: end - location), with: "")
            } else {
                edit(text, &map, replacing: NSRange(location: location, length: 0),
                     with: pieces.randomElement(using: &random)!)
            }
        }
    }

    /// Moves a position off the middle of an emoji (surrogate pair) or a \r\n pair,
    /// since a real text view never splits those.
    private func snapped(_ location: Int, in text: NSString) -> Int {
        guard location < text.length else { return text.length }
        return text.rangeOfComposedCharacterSequence(at: location).location
    }
}

/// Deterministic random numbers for repeatable property tests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
