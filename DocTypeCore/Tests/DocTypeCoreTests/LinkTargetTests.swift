// Tests for what ⌘-clicking a link opens.

import Foundation
import Testing
@testable import DocTypeCore

struct LinkTargetTests {
    private let root = URL(fileURLWithPath: "/Lib")

    private func resolve(_ destination: String, from note: String = "Uni/Algo/Graphs.md") -> LinkTarget? {
        LinkTarget.resolve(destination, fromNote: note, libraryRoot: root)
    }

    @Test func urlsWithASchemeOpenWithTheSystem() {
        #expect(resolve("https://swift.org/a?b#c") == .external(URL(string: "https://swift.org/a?b#c")!))
        #expect(resolve("mailto:me@example.com") == .external(URL(string: "mailto:me@example.com")!))
    }

    @Test func notesAreRelativeToTheNotesFolder() {
        #expect(resolve("Trees.md") == .note("Uni/Algo/Trees.md"))
        #expect(resolve("../Exams/Week%201.md#q2") == .note("Uni/Exams/Week 1.md"))
        #expect(resolve("./Heaps.MD") == .note("Uni/Algo/Heaps.MD"))
        #expect(resolve("/Home/Todo.md") == .note("Home/Todo.md"))  // from the library root
        #expect(resolve("Top.md", from: "Note.md") == .note("Top.md"))
    }

    @Test func otherFilesOpenWithTheirApp() {
        #expect(resolve("img/graph.pdf") == .external(URL(fileURLWithPath: "/Lib/Uni/Algo/img/graph.pdf")))
        #expect(resolve("../../../Outside.md") == .external(URL(fileURLWithPath: "/Outside.md")))
    }

    @Test func anchorsAndEmptyLinksDoNothing() {
        #expect(resolve("#heading") == nil)
        #expect(resolve("  ") == nil)
    }
}
