// Tests for attaching files to notes and the markdown that links them.

import Foundation
import Testing
@testable import DocTypeCore

struct AttachmentTests {
    @Test func filesAreCopiedIntoTheNotebooksAttachmentsFolder() async throws {
        let library = try TemporaryLibrary()
        let lib = Library(root: library.root)
        try FileManager.default.createDirectory(at: library.root.appending(path: "Uni/Algo"), withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory.appending(path: "Graph \(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let first = try await lib.attach(fileAt: outside, toNote: "Uni/Algo/Graphs.md")
        let second = try await lib.attach(fileAt: outside, toNote: "Uni/Algo/Trees.md")

        let name = (outside.lastPathComponent as NSString).deletingPathExtension
        #expect(first == "attachments/\(name).png")
        #expect(second == "attachments/\(name) 2.png")  // never overwrites
        #expect(FileManager.default.contents(atPath: library.root.appending(path: "Uni/Algo/\(first)").path) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: outside.path))  // copied, not moved
    }

    @Test func pastedDataAndRootNotes() async throws {
        let library = try TemporaryLibrary()
        let lib = Library(root: library.root)
        let path = try await lib.attach(data: Data([9]), named: "Pasted image.png", toNote: "Top.md")
        #expect(path == "attachments/Pasted image.png")
        #expect(FileManager.default.fileExists(atPath: library.root.appending(path: "attachments/Pasted image.png").path))
    }

    @Test func filesAlreadyInTheLibraryAreLinkedWhereTheyAre() async throws {
        let library = try TemporaryLibrary()
        let lib = Library(root: library.root)
        try FileManager.default.createDirectory(at: library.root.appending(path: "Home/img"), withIntermediateDirectories: true)
        let inside = library.root.appending(path: "Home/img/cat.jpg")
        try Data([1]).write(to: inside)

        #expect(try await lib.attach(fileAt: inside, toNote: "Uni/Algo/Graphs.md") == "../../Home/img/cat.jpg")
        #expect(try await lib.attach(fileAt: inside, toNote: "Home/Pets.md") == "img/cat.jpg")
        #expect(!FileManager.default.fileExists(atPath: library.root.appending(path: "Home/attachments").path))
    }

    @Test func attachmentsFoldersAreNotNotebooks() async throws {
        let library = try TemporaryLibrary()
        let lib = Library(root: library.root)
        _ = try await lib.attach(data: Data([9]), named: "a.png", toNote: "Uni/Graphs.md")
        try "x".write(to: library.root.appending(path: "Uni/Graphs.md"), atomically: true, encoding: .utf8)
        try await lib.scan()
        #expect(await lib.index.notebooks.map(\.path) == ["Uni"])
    }

    @Test func markdownForAttachments() {
        #expect(AttachmentMarkdown.markdown(forPath: "attachments/Pasted image (1).png", isImage: true)
                == "![Pasted image (1)](attachments/Pasted%20image%20%281%29.png)")
        #expect(AttachmentMarkdown.markdown(forPath: "../Slides/Week 3.pdf", isImage: false)
                == "[Week 3](../Slides/Week%203.pdf)")
        // And they resolve back to the file.
        #expect(LinkTarget.resolve("attachments/Pasted%20image%20%281%29.png", fromNote: "Uni/N.md",
                                   libraryRoot: URL(fileURLWithPath: "/L"))
                == .external(URL(fileURLWithPath: "/L/Uni/attachments/Pasted image (1).png")))
    }
}
