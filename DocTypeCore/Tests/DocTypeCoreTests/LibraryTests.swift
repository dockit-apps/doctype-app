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

struct LibrarySaveTests {
    @Test func saveWritesFileAndUpdatesIndex() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Uni/a.md", "old", modified: Date(timeIntervalSince1970: 1_000))
        let library = Library(root: folder.root)
        try await library.scan()

        try await library.save("Uni/a.md", text: "---\ntags: [x]\n---\nnew text")

        #expect(try await library.read("Uni/a.md") == "---\ntags: [x]\n---\nnew text")
        let note = try #require(await library.index.notes["Uni/a.md"])
        #expect(note.snippet == "new text")
        #expect(note.tags == ["x"])
        #expect(note.modified > Date(timeIntervalSince1970: 1_000))
    }

    @Test func saveLeavesNoTemporaryFilesBehind() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("a.md", "old")
        let library = Library(root: folder.root)

        try await library.save("a.md", text: "new")

        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.root.path)
        #expect(contents == ["a.md"])
    }

    @Test func readingAMissingNoteThrows() async throws {
        let library = Library(root: try TemporaryLibrary().root)
        await #expect(throws: (any Error).self) { try await library.read("missing.md") }
    }
}

struct CreateNoteTests {
    @Test func createsUntitledThenNumberedNames() async throws {
        let folder = try TemporaryLibrary()
        try folder.makeFolder("Uni")
        let library = Library(root: folder.root)

        let first = try await library.createNote(in: "Uni")
        let second = try await library.createNote(in: "Uni")
        let atRoot = try await library.createNote(in: "")

        #expect(first == "Uni/Untitled.md")
        #expect(second == "Uni/Untitled 2.md")
        #expect(atRoot == "Untitled.md")
        #expect(await library.index.notes[second] != nil)
    }

    @Test func existingFileWithDifferentCaseCountsAsTaken() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("untitled.md", "keep me")
        let library = Library(root: folder.root)

        let path = try await library.createNote(in: "")

        #expect(path == "Untitled 2.md")  // APFS is case-insensitive
        #expect(try await library.read("untitled.md") == "keep me")
    }
}
