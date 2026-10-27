// Tests for picking up changes made by other programs.
// Files are changed through /bin/sh, because FSEvents ignores this process's own writes.

import Foundation
import Testing
@testable import DocTypeCore

struct WatchingTests {
    /// Runs a shell command in the library folder, like an external editor or git would.
    private func externally(_ command: String, in root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
    }

    /// Waits for the next external change; nil if nothing arrives within `timeout`.
    private func nextChange(of library: Library, timeout: Duration = .seconds(3)) async throws -> Library.Change? {
        try await withThrowingTaskGroup(of: Library.Change?.self) { group in
            group.addTask {
                var iterator = library.changes.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Waits until the index satisfies `condition`. FSEvents may split one shell
    /// command's changes across batches (`NoDefer` sends the first change at once).
    private func waitForIndex(
        of library: Library, timeout: Duration = .seconds(3), _ condition: (LibraryIndex) -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(await library.index) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func watchedLibrary(_ folder: TemporaryLibrary) async throws -> Library {
        let library = Library(root: folder.root)
        try await library.scan()
        await library.startWatching()
        try await Task.sleep(for: .milliseconds(200))  // let FSEvents attach
        return library
    }

    @Test func newNoteFromAnotherProgramAppearsInIndex() async throws {
        let folder = try TemporaryLibrary()
        let library = try await watchedLibrary(folder)

        try externally("printf 'hello from vim' > 'New.md'", in: folder.root)

        #expect(try await nextChange(of: library) == .notesChanged(["New.md"]))
        #expect(await library.index.notes["New.md"]?.snippet == "hello from vim")
    }

    @Test func modifiedAndDeletedNotesUpdateIndex() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("a.md", "old")
        try folder.write("b.md", "bye")
        let library = try await watchedLibrary(folder)

        try externally("printf 'new' > a.md && rm b.md", in: folder.root)

        #expect(try await waitForIndex(of: library) { index in
            index.notes["a.md"]?.snippet == "new" && index.notes["b.md"] == nil
        })
    }

    @Test func newFolderTriggersRescanAndShowsNotebook() async throws {
        let folder = try TemporaryLibrary()
        let library = try await watchedLibrary(folder)

        try externally("mkdir 'Lectures' && printf x > 'Lectures/One.md'", in: folder.root)

        #expect(try await waitForIndex(of: library) { index in
            index.notebooks.map(\.path) == ["Lectures"] && index.notes["Lectures/One.md"] != nil
        })
    }

    @Test func changesInsideHiddenFoldersAreIgnored() async throws {
        let folder = try TemporaryLibrary()
        let library = try await watchedLibrary(folder)

        try externally("mkdir .git && printf x > .git/notes.md && printf y > visible.md", in: folder.root)

        #expect(try await nextChange(of: library) == .notesChanged(["visible.md"]))
    }

    @Test func ownSavesAreNotReportedAsExternalChanges() async throws {
        let folder = try TemporaryLibrary()
        let library = try await watchedLibrary(folder)

        try await library.save("mine.md", text: "typed in DocType")

        #expect(try await nextChange(of: library, timeout: .seconds(1)) == nil)
    }

    @Test func gitCheckoutOf200FilesLeavesIndexMatchingAFreshScan() async throws {
        let folder = try TemporaryLibrary()
        for number in 1...300 { try folder.write("Notebook \(number % 7)/Note \(number).md", "original \(number)") }
        let git = "git -c user.name=t -c user.email=t@t"
        try externally(
            "git init -q && \(git) add -A && \(git) commit -qm base && "
                + "ls */*.md | head -200 | while read -r f; do printf 'changed' > \"$f\"; done && "
                + "\(git) commit -qam change",
            in: folder.root
        )
        let library = try await watchedLibrary(folder)

        try externally("git checkout -q HEAD~1", in: folder.root)

        let settled = try await waitForIndex(of: library, timeout: .seconds(5)) { index in
            index.notes.count == 300 && index.notes.values.allSatisfy { $0.snippet.hasPrefix("original") }
        }
        let fresh = Library(root: folder.root)
        try await fresh.scan()
        #expect(settled)
        #expect(await library.index.notes.mapValues(\.snippet) == fresh.index.notes.mapValues(\.snippet))
    }

    @Test func deletingTheLibraryFolderIsReported() async throws {
        let folder = try TemporaryLibrary()
        let library = try await watchedLibrary(folder)

        try externally("rm -rf '\(folder.root.path)'", in: folder.root.deletingLastPathComponent())

        #expect(try await nextChange(of: library) == .libraryMissing)
    }
}

struct ConflictCopyTests {
    private let date = Date(timeIntervalSince1970: 1_793_000_000)  // fixed for stable names
    private var stamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: date)
    }

    @Test func nameIsTitlePlusTimestampInSameFolder() {
        let path = FileNaming.conflictCopyPath(for: "Uni/Graphs.md", in: "Uni", date: date) { _ in false }
        #expect(path == "Uni/Graphs (conflict \(stamp)).md")
    }

    @Test func takenNamesGetANumber() {
        let taken: Set = ["Graphs (conflict \(stamp)).md", "Graphs (conflict \(stamp)) 2.md"]
        let path = FileNaming.conflictCopyPath(for: "Graphs.md", in: "", date: date) { taken.contains($0) }
        #expect(path == "Graphs (conflict \(stamp)) 3.md")
    }

    @Test func libraryWritesCopyAndFallsBackToRootWhenFolderIsGone() async throws {
        let folder = try TemporaryLibrary()
        let library = Library(root: folder.root)

        let copy = try await library.saveConflictCopy(of: "Gone/Graphs.md", text: "my text", date: date)

        #expect(copy == "Graphs (conflict \(stamp)).md")
        #expect(try await library.read(copy) == "my text")
        #expect(await library.index.notes[copy] != nil)
    }
}
