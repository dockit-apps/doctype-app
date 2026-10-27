// Tests for renaming, moving and trashing notes and for notebook operations.

import Foundation
import Testing
@testable import DocTypeCore

struct NoteOrganizingTests {
    /// The returned TemporaryLibrary deletes its folder when released, so tests keep it alive.
    private func library(with files: [String: String]) async throws -> (TemporaryLibrary, Library) {
        let folder = try TemporaryLibrary()
        for (path, text) in files { try folder.write(path, text) }
        let library = Library(root: folder.root)
        try await library.scan()
        return (folder, library)
    }

    @Test func renameMovesFileAndUpdatesIndex() async throws {
        let (folder, library) = try await library(with: ["Uni/Draft.md": "body"])

        let newPath = try await library.renameNote("Uni/Draft.md", to: "  Graph Search  ")

        #expect(newPath == "Uni/Graph Search.md")
        #expect(FileManager.default.fileExists(atPath: folder.root.appending(path: newPath).path))
        let index = await library.index
        #expect(index.notes["Uni/Draft.md"] == nil)
        #expect(index.notes[newPath]?.title == "Graph Search")
        #expect(index.notes[newPath]?.snippet == "body")
    }

    @Test func renameRefusesToOverwrite() async throws {
        let (folder, library) = try await library(with: ["a.md": "a", "b.md": "b"])

        await #expect(throws: LibraryError.nameTaken("b")) { try await library.renameNote("a.md", to: "b") }
        #expect(try await library.read("b.md") == "b")
        withExtendedLifetime(folder) {}
    }

    @Test func caseOnlyRenameWorksOnCaseInsensitiveDisk() async throws {
        let (folder, library) = try await library(with: ["note.md": "x"])

        let newPath = try await library.renameNote("note.md", to: "Note")

        #expect(newPath == "Note.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.root.path)
        #expect(names == ["Note.md"])
    }

    @Test(arguments: ["", "   ", "a/b", "a:b", ".hidden"])
    func invalidNamesAreRejected(name: String) async throws {
        let (folder, library) = try await library(with: ["a.md": ""])
        await #expect(throws: LibraryError.self) { try await library.renameNote("a.md", to: name) }
        withExtendedLifetime(folder) {}
    }

    @Test func moveNoteBetweenNotebooks() async throws {
        let (folder, library) = try await library(with: ["Uni/a.md": "x", "Personal/keep.md": ""])

        let newPath = try await library.moveNote("Uni/a.md", toNotebook: "Personal")
        let atRoot = try await library.moveNote(newPath, toNotebook: "")

        #expect(newPath == "Personal/a.md")
        #expect(atRoot == "a.md")
        #expect(await library.index.notes.keys.sorted() == ["Personal/keep.md", "a.md"])
        withExtendedLifetime(folder) {}
    }

    @Test func moveRefusesToOverwriteSameNameInTarget() async throws {
        let (folder, library) = try await library(with: ["Uni/a.md": "uni", "Personal/a.md": "personal"])
        await #expect(throws: LibraryError.nameTaken("a")) {
            try await library.moveNote("Uni/a.md", toNotebook: "Personal")
        }
        withExtendedLifetime(folder) {}
    }

    @Test func trashRemovesFileAndIndexEntry() async throws {
        let (folder, library) = try await library(with: ["a.md": "x"])

        let trashed = try #require(try await library.trashNote("a.md"))
        defer { try? FileManager.default.removeItem(at: trashed) }  // keep the real Trash clean

        #expect(!FileManager.default.fileExists(atPath: folder.root.appending(path: "a.md").path))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(await library.index.notes.isEmpty)
    }
}

struct NotebookOrganizingTests {
    @Test func createNotebookPicksFreeName() async throws {
        let folder = try TemporaryLibrary()
        try folder.makeFolder("Untitled Notebook")
        let library = Library(root: folder.root)

        let path = try await library.createNotebook(in: "")
        let nested = try await library.createNotebook(in: path, name: "Week 1")

        #expect(path == "Untitled Notebook 2")
        #expect(nested == "Untitled Notebook 2/Week 1")
        #expect(await library.index.notebooks.map(\.path) == ["Untitled Notebook", "Untitled Notebook 2"])
    }

    @Test func renameNotebookMovesAllNestedNotes() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Uni/a.md", "a")
        try folder.write("Uni/Algo/b.md", "b")
        let library = Library(root: folder.root)
        try await library.scan()

        let newPath = try await library.renameNotebook("Uni", to: "University")

        #expect(newPath == "University")
        #expect(await library.index.notes.keys.sorted() == ["University/Algo/b.md", "University/a.md"])
        #expect(await library.index.notebooks.first?.children?.first?.path == "University/Algo")
    }

    @Test func renameNotebookRefusesExistingName() async throws {
        let folder = try TemporaryLibrary()
        try folder.makeFolder("A")
        try folder.makeFolder("B")
        let library = Library(root: folder.root)
        await #expect(throws: LibraryError.nameTaken("B")) { try await library.renameNotebook("A", to: "B") }
    }
}
