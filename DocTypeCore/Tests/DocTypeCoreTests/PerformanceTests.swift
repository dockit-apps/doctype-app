// Local performance checks against a generated fixture library.
// Skipped unless DOCTYPE_FIXTURES points at output of Scripts/make-fixtures.swift:
//   DOCTYPE_FIXTURES=~/DocTypeFixtures swift test --filter PerformanceTests
// Debug builds are unoptimized, so these numbers are an upper bound.

import Foundation
import Testing
@testable import DocTypeCore

private let fixturesPath = ProcessInfo.processInfo.environment["DOCTYPE_FIXTURES"]

@Suite(.enabled(if: fixturesPath != nil, "Set DOCTYPE_FIXTURES to run"))
struct PerformanceTests {
    @Test func scanningTheFixtureLibraryStaysUnderBudget() async throws {
        let library = Library(root: URL(fileURLWithPath: fixturesPath!))
        let clock = ContinuousClock()

        let elapsed = try await clock.measure { try await library.scan() }

        let count = await library.index.notes.count
        print("Scanned \(count) notes in \(elapsed)")
        #expect(count >= 1_000)
        #expect(elapsed < .milliseconds(500))
    }

    @Test func typingInTheMiddleOfA5000LineNoteStaysUnderBudget() async throws {
        let url = URL(fileURLWithPath: fixturesPath!).appending(path: "Big/5000-lines.md")
        let body = String(Frontmatter.split(try String(contentsOf: url, encoding: .utf8)).body)
        let text = NSMutableString(string: body)
        let clock = ContinuousClock()

        var map = BlockMap()
        let open = clock.measure {
            map = BlockMap(text: text)
            _ = MarkdownStyler.spans(in: text, blocks: map.blocks)
        }
        print("Styled whole 5,000-line note in \(open)")

        // Type 300 characters at a paragraph in the middle, like a user would.
        var location = text.range(of: "Section", range: NSRange(location: text.length / 2, length: text.length / 2)).location
        var timings: [Duration] = []
        for character in String(repeating: "typing more words ", count: 17).prefix(300) {
            let insert = String(character)
            timings.append(clock.measure {
                text.replaceCharacters(in: NSRange(location: location, length: 0), with: insert)
                let dirty = map.update(text: text, editedRange: NSRange(location: location, length: 1), changeInLength: 1)
                _ = MarkdownStyler.spans(in: text, blocks: map.blocks(in: dirty))
            })
            location += 1
        }
        timings.sort()
        let median = timings[timings.count / 2], worst = timings.last!
        print("Per keystroke: median \(median), max \(worst)")
        #expect(map == BlockMap(text: text))
        #expect(median < .milliseconds(1))
        #expect(worst < .milliseconds(8))
    }
}
