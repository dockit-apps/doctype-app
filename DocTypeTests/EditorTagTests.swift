// Tag changes through the editor: they show up at once, undo like typing, and
// autosave writes only the tags line.

import AppKit
import DocTypeCore
import Foundation
import Testing
@testable import DocType

@MainActor
struct EditorTagTests {
    /// An editor (in a window, for its undo manager) showing `Note.md` with `text`.
    private func editor(showing text: String) async throws -> (EditorController, URL, NSWindow) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appending(path: "Note.md"), atomically: true, encoding: .utf8)
        let controller = EditorController()
        controller.library = Library(root: folder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.scrollView
        #expect(await controller.open("Note.md"))
        return (controller, folder, window)
    }

    private func onDisk(_ folder: URL) throws -> String {
        try String(contentsOf: folder.appending(path: "Note.md"), encoding: .utf8)
    }

    @Test func addingATagChangesOnlyTheTagsLine() async throws {
        let text = "---\ntitle: Graphs\ntags: [algo]\n---\n# Graphs\n\nBFS and DFS.\n"
        let (editor, folder, _) = try await editor(showing: text)
        defer { try? FileManager.default.removeItem(at: folder) }

        editor.addTag("exam")
        #expect(editor.tags == ["algo", "exam"])
        #expect(editor.textView.string == "# Graphs\n\nBFS and DFS.\n")  // the body is untouched
        await editor.save()

        #expect(try onDisk(folder) == "---\ntitle: Graphs\ntags: [algo, exam]\n---\n# Graphs\n\nBFS and DFS.\n")
    }

    @Test func tagChangesUndoAndRedo() async throws {
        let (editor, folder, _) = try await editor(showing: "Body\n")
        defer { try? FileManager.default.removeItem(at: folder) }

        editor.addTag("idea")
        #expect(editor.tags == ["idea"])

        editor.textView.undoManager?.undo()
        #expect(editor.tags.isEmpty)
        await editor.save()
        #expect(try onDisk(folder) == "Body\n")  // no empty frontmatter left behind

        editor.textView.undoManager?.redo()
        #expect(editor.tags == ["idea"])
        await editor.save()
        #expect(try onDisk(folder) == "---\ntags: [idea]\n---\nBody\n")
    }

    @Test func removingTheLastTagRemovesTheFrontmatter() async throws {
        let (editor, folder, _) = try await editor(showing: "---\ntags: [draft]\n---\nBody\n")
        defer { try? FileManager.default.removeItem(at: folder) }

        editor.removeTag("DRAFT")  // any case
        await editor.save()

        #expect(editor.tags.isEmpty)
        #expect(try onDisk(folder) == "Body\n")
    }

    @Test func addingAnExistingTagInAnotherCaseChangesNothing() async throws {
        let (editor, folder, _) = try await editor(showing: "---\ntags: [Algo]\n---\nBody\n")
        defer { try? FileManager.default.removeItem(at: folder) }

        editor.addTag("algo")

        #expect(editor.tags == ["Algo"])
        #expect(editor.textView.undoManager?.canUndo != true)
    }
}
