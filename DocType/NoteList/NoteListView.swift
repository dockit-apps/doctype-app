// The middle column: notes for the current sidebar selection, newest first,
// narrowed by the search field above it.

import DocTypeCore
import SwiftUI

struct NoteListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var model = model
        List(model.visibleNotes, selection: $model.selectedNotePath) { note in
            NoteRow(note: note)
        }
        .searchable(text: $model.searchQuery, placement: .toolbar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .onSubmit(of: .search) { model.openFirstSearchResult() }
        .onChange(of: model.searchFocusRequest) { isSearchFocused = true }
        .overlay {
            if model.libraryURL != nil, model.visibleNotes.isEmpty {
                if model.isScanning {
                    ProgressView()
                } else if !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView.search(text: model.searchQuery)
                } else {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: "note.text")
                    } description: {
                        Text("Create one with New Note\(newNoteShortcut).")
                    } actions: {
                        Button("New Note") { model.commands.run(.newNote) }
                    }
                }
            }
        }
    }

    /// What's empty: the library, a notebook, or a tag.
    private var emptyTitle: String {
        switch model.sidebarSelection ?? .all {
        case .all: "No Notes"
        case .notebook(let path): "No Notes in \((path as NSString).lastPathComponent)"
        case .tag(let tag): "No Notes Tagged #\(tag)"
        }
    }

    private var newNoteShortcut: String {
        model.shortcuts.shortcuts(for: .newNote).first.map { " (\($0.displayString))" } ?? ""
    }
}
