// Reading note files in any encoding: UTF-8 is editable, anything else is
// read (and listed, and searchable) but marked so the editor won't save it.

import Foundation
import Testing
@testable import DocTypeCore

struct NoteTextTests {
    @Test func utf8IsReadAsIs() {
        #expect(NoteText.decode(Data("Özet 🎓".utf8)) == NoteText(text: "Özet 🎓", isUTF8: true))
        #expect(NoteText.decode(Data()) == NoteText(text: "", isUTF8: true))
    }

    @Test func otherEncodingsAreReadButNotUTF8() {
        let latin = NoteText.decode(Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x80]))  // "Café €" in Windows-1252
        #expect(latin == NoteText(text: "Café €", isUTF8: false))
        let utf16 = NoteText.decode("# Notes".data(using: .utf16)!)  // with its byte-order mark
        #expect(utf16 == NoteText(text: "# Notes", isUTF8: false))
        // Bytes Windows-1252 leaves undefined still read as something.
        #expect(!NoteText.decode(Data([0x61, 0x81, 0x8D, 0xFF])).text.isEmpty)
    }

    @Test func aNonUTF8NoteIsListedSearchableAndReadable() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeNoteText-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("Résumé of the café meeting".data(using: .windowsCP1252)!).write(to: folder.appending(path: "Old.md"))

        let library = Library(root: folder)
        try await library.scan()
        let note = try #require(await library.index.notes["Old.md"])
        #expect(note.snippet == "Résumé of the café meeting")
        #expect(NoteSearch("cafe").results(in: await library.index, filter: .all).map(\.path) == ["Old.md"])
        #expect(try await library.readNote("Old.md") == NoteText(text: "Résumé of the café meeting", isUTF8: false))
    }
}
