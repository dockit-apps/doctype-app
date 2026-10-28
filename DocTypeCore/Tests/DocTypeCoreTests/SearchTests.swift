// Tests for full-text search and for counting a note's tasks.

import Foundation
import Testing
@testable import DocTypeCore

struct SearchTests {
    private func note(_ path: String, _ text: String, age: TimeInterval = 0) -> NoteSummary {
        NoteSummary.make(path: path, text: text, modified: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    private func search(_ query: String, in notes: [NoteSummary], filter: LibraryIndex.Filter = .all) -> [String] {
        NoteSearch(query).results(in: LibraryIndex(notes: notes, folders: []), filter: filter).map(\.title)
    }

    // MARK: Matching

    @Test func ignoresCaseAccentsAndWidth() {
        let notes = [note("Özet.md", "Ders notları"), note("Other.md", "ÇALIŞMA planı"), note("Wide.md", "ＡＢＣ")]
        #expect(search("ozet", in: notes) == ["Özet"])
        #expect(search("calisma", in: notes) == ["Other"])
        #expect(search("PLANI", in: notes) == ["Other"])    // dotless ı matches i
        #expect(search("notlari", in: notes) == ["Özet"])
        #expect(search("abc", in: notes) == ["Wide"])
    }

    @Test func everyWordMustMatchSomewhere() {
        let notes = [note("Graphs.md", "BFS and DFS"), note("Trees.md", "DFS only")]
        #expect(search("graph dfs", in: notes) == ["Graphs"])  // title + body, partial word
        #expect(search("  dfs   bfs ", in: notes) == ["Graphs"])
        #expect(search("heap", in: notes).isEmpty)
        #expect(NoteSearch("   ").isEmpty)
    }

    @Test func frontmatterTagsAreSearched() {
        #expect(search("exam", in: [note("A.md", "---\ntags: [exam]\n---\nbody")]) == ["A"])
    }

    // MARK: Ranking and scope

    @Test func titleHitsComeFirstThenNewestFirst() {
        let notes = [
            note("Recent body hit.md", "about graphs", age: 0),
            note("Old Graphs.md", "nothing", age: 300),
            note("Older body hit.md", "graphs again", age: 200),
            note("New Graphs.md", "nothing", age: 100),
        ]
        #expect(search("graphs", in: notes) == ["New Graphs", "Old Graphs", "Recent body hit", "Older body hit"])
    }

    @Test func searchesOnlyTheSidebarSelection() {
        let notes = [note("Uni/A.md", "graphs"), note("Uni/Algo/B.md", "graphs"), note("Home/C.md", "graphs")]
        #expect(Set(search("graphs", in: notes, filter: .notebook("Uni"))) == ["A", "B"])
        #expect(search("graphs", in: notes).count == 3)
    }

    // MARK: Task progress

    private func tasks(_ body: String) -> TaskProgress {
        NoteSummary.make(path: "N.md", text: body, modified: .now).tasks
    }

    @Test func countsOpenAndCheckedTasks() {
        let body = """
        - [ ] open
        - [x] done
        * [X] done too
        1. [ ] numbered
          - [ ] nested
        > - [x] quoted
        - [ ]
        """
        #expect(tasks(body) == TaskProgress(done: 3, total: 7))
    }

    @Test func ignoresThingsThatOnlyLookLikeTasks() {
        let body = """
        [ ] no list marker
        - [] no space inside
        - [ ]no space after
        -[ ] no space before
        - plain item
        text with - [ ] in it
        """
        #expect(tasks(body) == .none)
    }

    @Test func tasksInsideCodeFencesDontCount() {
        let body = """
        - [ ] real
        ```markdown
        - [ ] example
        ```
        ~~~~
        - [x] example
        ~~~
        - [x] still inside: ~~~ is shorter than the opening ~~~~
        ~~~~
        - [x] real
        ``` not closed by an info string
        """
        #expect(tasks(body) == TaskProgress(done: 1, total: 2))
    }

    @Test func frontmatterIsNotCounted() {
        #expect(tasks("---\ntitle: \"- [ ] x\"\n---\n- [ ] a\r\n- [x] b\r\n") == TaskProgress(done: 1, total: 2))
    }
}
