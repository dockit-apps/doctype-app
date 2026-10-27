// The middle column: notes for the current sidebar selection, newest first.

import SwiftUI

struct NoteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(model.visibleNotes, selection: $model.selectedNotePath) { note in
            NoteRow(note: note)
        }
        .overlay {
            if model.libraryURL != nil, model.visibleNotes.isEmpty {
                if model.isScanning {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Notes", systemImage: "note.text")
                }
            }
        }
    }
}
