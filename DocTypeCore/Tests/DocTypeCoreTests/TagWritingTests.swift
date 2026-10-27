// Tests for writing tags into frontmatter, tag counts, and creating tagged notes.

import Foundation
import Testing
@testable import DocTypeCore

struct TagWritingTests {
    private func set(_ tags: [String], _ raw: String?) -> String {
        Frontmatter.settingTags(tags, in: raw)
    }

    @Test func noteWithoutFrontmatterGetsOne() {
        #expect(set(["algo"], nil) == "---\ntags: [algo]\n---\n")
        #expect(set([], nil) == "")
        #expect(Frontmatter.settingTags(["a"], inNote: "# Title\nbody") == "---\ntags: [a]\n---\n# Title\nbody")
    }

    @Test func eachListStyleIsKept() {
        #expect(set(["a", "b", "c"], "---\ntags: [a, b]\n---\n") == "---\ntags: [a, b, c]\n---\n")
        #expect(set(["a", "b", "c"], "---\ntags: a, b\n---\n") == "---\ntags: a, b, c\n---\n")
        #expect(set(["a", "c"], "---\ntags:\n  - a\n  - b\n---\n") == "---\ntags:\n  - a\n  - c\n---\n")
        #expect(set(["a", "b"], "---\ntags:\n    - a\n---\n") == "---\ntags:\n    - a\n    - b\n---\n")  // indentation kept
    }

    @Test func otherKeysAndCommentsStayByteForByte() {
        let raw = "---\ntitle: \"Graphs: BFS\"  # keep me\ntags: [a]\n# a comment\ndate: 2026-10-27\n---\n"
        #expect(set(["a", "b"], raw) == "---\ntitle: \"Graphs: BFS\"  # keep me\ntags: [a, b]\n# a comment\ndate: 2026-10-27\n---\n")
        let blockFollowedByKey = "---\ntags:\n  - a\nauthor: me\n---\n"
        #expect(set(["b"], blockFollowedByKey) == "---\ntags:\n  - b\nauthor: me\n---\n")
    }

    @Test func crlfLineEndingsAreKept() {
        #expect(set(["a", "b"], "---\r\nid: 1\r\ntags: [a]\r\n---\r\n") == "---\r\nid: 1\r\ntags: [a, b]\r\n---\r\n")
    }

    @Test func frontmatterWithoutTagsGetsTheKeyAtTheEnd() {
        #expect(set(["x"], "---\ntitle: T\n---\n") == "---\ntitle: T\ntags: [x]\n---\n")
        #expect(set([], "---\ntitle: T\n---\n") == "---\ntitle: T\n---\n")
    }

    @Test func removingTheLastTagRemovesTheKeyAndAnEmptyBlock() {
        #expect(set([], "---\ntags: [a]\n---\n") == "")
        #expect(set([], "---\ntags:\n  - a\n  - b\n---\n") == "")
        #expect(set([], "---\ntitle: T\ntags: [a]\n---\n") == "---\ntitle: T\n---\n")
        #expect(set([], "---\n# only a comment\ntags: [a]\n---\n") == "---\n# only a comment\n---\n")
    }

    @Test func specialCharactersAreQuotedAndReadBack() {
        let raw = set(["c++", "a, b", "#hash", "x: y", "ok"], nil)
        #expect(raw == "---\ntags: [c++, \"a, b\", \"#hash\", \"x: y\", ok]\n---\n")
        #expect(Frontmatter.split(raw + "body").frontmatter?.tags == ["c++", "a, b", "#hash", "x: y", "ok"])
    }

    @Test func roundTripsThroughTheReader() {
        for raw in ["---\ntags: [a]\n---\n", "---\ntags: a\n---\n", "---\ntags:\n  - a\n---\n", "---\nk: v\n---\n"] {
            let written = set(["a", "Graph Theory", "b"], raw)
            #expect(Frontmatter.split(written + "body").frontmatter?.tags == ["a", "Graph Theory", "b"])
        }
    }

    @Test func addingAndRemovingIgnoreCase() {
        #expect(Frontmatter.adding("algo", to: ["Algo"]) == ["Algo"])
        #expect(Frontmatter.adding("new", to: ["Algo"]) == ["Algo", "new"])
        #expect(Frontmatter.removing("ALGO", from: ["Algo", "x"]) == ["x"])
        #expect(Frontmatter.cleanedTag("  #exam ") == "exam")
        #expect(Frontmatter.cleanedTag(" # ") == nil)
    }

    // MARK: Index and library

    @Test func tagCountsMergeCaseAndUseTheMostCommonSpelling() {
        let notes = [
            NoteSummary.make(path: "a.md", text: "---\ntags: [Algo, exam]\n---\n", modified: .now),
            NoteSummary.make(path: "b.md", text: "---\ntags: [algo]\n---\n", modified: .now),
            NoteSummary.make(path: "c.md", text: "---\ntags: [algo, Exam]\n---\n", modified: .now),
        ]
        let index = LibraryIndex(notes: notes, folders: [])
        #expect(index.tagCounts() == [TagCount(name: "algo", count: 3), TagCount(name: "Exam", count: 2)])
    }

    @Test func newNoteCanStartWithATag() async throws {
        let folder = try TemporaryLibrary()
        let library = Library(root: folder.root)

        let path = try await library.createNote(in: "", tags: ["exam"])

        #expect(try await library.read(path) == "---\ntags: [exam]\n---\n")
        #expect(await library.index.notes[path]?.tags == ["exam"])
    }
}
