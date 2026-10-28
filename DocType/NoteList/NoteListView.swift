// The middle column: notes for the current sidebar selection, newest first,
// narrowed by the search field above it.

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
                    ContentUnavailableView("No Notes", systemImage: "note.text")
                }
            }
        }
    }
}
