// Tests for note titles, notebook paths and snippet extraction rules.

import Foundation
import Testing
@testable import DocTypeCore

struct NoteSummaryTests {
    private func summary(_ text: String, path: String = "Uni/Graphs.md") -> NoteSummary {
        NoteSummary.make(path: path, text: text, modified: .distantPast)
    }

    @Test func titleAndNotebookComeFromPath() {
        let note = summary("", path: "University/Algorithms/Graph Search.md")
        #expect(note.title == "Graph Search")
        #expect(note.notebook == "University/Algorithms")
        #expect(summary("", path: "Inbox.md").notebook == "")
    }

    @Test func tagsComeFromFrontmatter() {
        #expect(summary("---\ntags: [algo]\n---\nBody").tags == ["algo"])
    }

    @Test func snippetSkipsFrontmatterAndHeadingThatRepeatsTitle() {
        #expect(summary("---\ntags: [a]\n---\n# Graphs\n\nBFS visits nodes level by level.").snippet
            == "BFS visits nodes level by level.")
    }

    @Test func snippetKeepsOtherHeadings() {
        #expect(summary("# Lecture 3\nBFS").snippet == "Lecture 3 BFS")
    }

    @Test func snippetStripsMarkdown() {
        let text = "> **Bold** and *italic* with `code` and ~~gone~~\n- [ ] [link text](https://x.y)\n1. item"
        #expect(summary(text).snippet == "Bold and italic with code and gone link text item")
    }

    @Test func snippetKeepsSnakeCase() {
        #expect(summary("call my_func_name now").snippet == "call my_func_name now")
    }

    @Test func snippetSkipsFencesAndRulesButKeepsCode() {
        #expect(summary("```swift\nlet x = 1\n```\n---\nAfter").snippet == "let x = 1 After")
    }

    @Test func snippetIsCappedAt200Characters() {
        let long = String(repeating: "word ", count: 100)
        #expect(summary(long).snippet.count == 200)
    }

    @Test func emptyNoteHasEmptySnippet() {
        #expect(summary("\n\n").snippet == "")
    }
}
