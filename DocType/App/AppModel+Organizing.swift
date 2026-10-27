// AppModel actions that rename, move and trash notes and create or rename notebooks.
// Each one asks the Library actor to do the file work, then fixes up the selection
// and the open note.

import DocTypeCore
import Foundation

extension AppModel {
    /// The notebook selected in the sidebar, or `""` (library root) otherwise.
    var selectedNotebook: String {
        if case .notebook(let path) = sidebarSelection { path } else { "" }
    }

    // MARK: - Notes

    /// Renames the open note's file. Returns false (and shows why) if it failed.
    @discardableResult
    func renameOpenNote(to title: String) async -> Bool {
        guard let library, let path = editor.path else { return false }
        do {
            try await editor.whileMoving { try await library.renameNote(path, to: title) }
            selectedNotePath = editor.path
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Shows the palette as a notebook picker for the selected note.
    func showMoveNotePicker() {
        guard let path = selectedNotePath else { return }
        let currentFolder = (path as NSString).deletingLastPathComponent
        var destinations = flattened(index.notebooks).map(\.path)
        if !currentFolder.isEmpty { destinations.insert("", at: 0) }
        let items = destinations.filter { $0 != currentFolder }.map { folder in
            PaletteItem(
                id: folder.isEmpty ? "/" : folder,
                title: folder.isEmpty ? "Library (no notebook)" : folder.replacingOccurrences(of: "/", with: " › "),
                detail: nil,
                action: { [weak self] in Task { await self?.moveSelectedNote(to: folder) } }
            )
        }
        showPalette(Palette(placeholder: "Move to notebook", items: items))
    }

    func moveSelectedNote(to folder: String) async {
        guard let library, let path = selectedNotePath else { return }
        do {
            if path == editor.path {
                try await editor.whileMoving { try await library.moveNote(path, toNotebook: folder) }
                selectedNotePath = editor.path
            } else {
                selectedNotePath = try await library.moveNote(path, toNotebook: folder)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves the selected note to the Trash and selects the next one in the list.
    func trashSelectedNote() async {
        guard let library, let path = selectedNotePath else { return }
        let notes = visibleNotes
        let position = notes.firstIndex { $0.path == path }
        do {
            if path == editor.path { await editor.flush() }
            try await library.trashNote(path)
            if path == editor.path { await editor.discard() }
            let remaining = notes.filter { $0.path != path }
            selectedNotePath = position.flatMap { remaining.isEmpty ? nil : remaining[min($0, remaining.count - 1)].path }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Notebooks

    /// Creates "Untitled Notebook" inside the selected notebook and asks for a name.
    func createNotebook() async {
        guard let library else { return }
        do {
            let path = try await library.createNotebook(in: selectedNotebook)
            sidebarSelection = .notebook(path)
            beginRenamingNotebook(path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginRenamingNotebook(_ path: String) {
        notebookBeingRenamed = path
        notebookNameDraft = (path as NSString).lastPathComponent
    }

    /// Renames the notebook being edited to `notebookNameDraft`.
    func commitNotebookRename() async {
        guard let library, let path = notebookBeingRenamed else { return }
        notebookBeingRenamed = nil
        let rewrite = { (notePath: String, newFolder: String) -> String in
            notePath.hasPrefix(path + "/") ? newFolder + notePath.dropFirst(path.count) : notePath
        }
        do {
            var newFolder = path
            if let openPath = editor.path, openPath.hasPrefix(path + "/") {
                try await editor.whileMoving {
                    newFolder = try await library.renameNotebook(path, to: notebookNameDraft)
                    return rewrite(openPath, newFolder)
                }
            } else {
                newFolder = try await library.renameNotebook(path, to: notebookNameDraft)
            }
            selectedNotePath = selectedNotePath.map { rewrite($0, newFolder) }
            if case .notebook(let selected) = sidebarSelection {
                sidebarSelection = .notebook(selected == path ? newFolder : rewrite(selected, newFolder))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func flattened(_ notebooks: [Notebook]) -> [Notebook] {
        notebooks.flatMap { [$0] + flattened($0.children ?? []) }
    }
}
