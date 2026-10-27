// Tests for scanning a library folder and filtering the index.

import Foundation
import Testing
@testable import DocTypeCore

/// A throwaway library folder that removes itself.
final class TemporaryLibrary {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "DocTypeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String = "", modified: Date? = nil) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
    }
}

struct LibraryTests {
    @Test func scanFindsNotesAndNotebooksAndSkipsHiddenAndNonMarkdown() async throws {
        let library = try TemporaryLibrary()
        try library.write("Inbox.md", "hello")
        try library.write("University/Algorithms/Graphs.md", "# Graphs")
        try library.write(".git/config.md", "hidden")
        try library.write(".obsidian/workspace.md", "hidden")
        try library.write("University/notes.txt", "not markdown")
        try library.makeFolder("Empty Notebook")

        let index = try await scan(library.root)

        #expect(Set(index.notes.keys) == ["Inbox.md", "University/Algorithms/Graphs.md"])
        #expect(index.notebooks.map(\.path) == ["Empty Notebook", "University"])
        #expect(index.notebooks[1].children?.map(\.path) == ["University/Algorithms"])
    }

    @Test func notesAreSortedNewestFirst() async throws {
        let library = try TemporaryLibrary()
        try library.write("old.md", modified: Date(timeIntervalSince1970: 1_000))
        try library.write("new.md", modified: Date(timeIntervalSince1970: 3_000))
        try library.write("middle.md", modified: Date(timeIntervalSince1970: 2_000))

        let index = try await scan(library.root)

        #expect(index.notes(matching: .all).map(\.title) == ["new", "middle", "old"])
    }

    @Test func notebookFilterIncludesSubfolders() async throws {
        let library = try TemporaryLibrary()
        try library.write("Uni/a.md")
        try library.write("Uni/Algo/b.md")
        try library.write("University/c.md")  // shares a prefix but is a different notebook
        try library.write("root.md")

        let index = try await scan(library.root)

        #expect(Set(index.notes(matching: .notebook("Uni")).map(\.title)) == ["a", "b"])
        #expect(index.notes(matching: .notebook("Uni/Algo")).map(\.title) == ["b"])
    }

    @Test func tagFilterIsCaseInsensitive() async throws {
        let library = try TemporaryLibrary()
        try library.write("a.md", "---\ntags: [Algo]\n---\n")
        try library.write("b.md", "---\ntags: [other]\n---\n")

        let index = try await scan(library.root)

        #expect(index.notes(matching: .tag("algo")).map(\.title) == ["a"])
    }

    @Test func scanPublishesSnapshot() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("a.md")
        let library = Library(root: folder.root)

        try await library.scan()
        var iterator = library.updates.makeAsyncIterator()
        let published = await iterator.next()

        #expect(published?.notes.count == 1)
    }

    private func scan(_ root: URL) async throws -> LibraryIndex {
        let library = Library(root: root)
        try await library.scan()
        return await library.index
    }
}
