// Sidebar: "All Notes" plus the notebook folder tree. Selecting an item filters the note list.

import DocTypeCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("All Notes", systemImage: "note.text")
                .tag(LibraryIndex.Filter.all)

            if !model.index.notebooks.isEmpty {
                Section("Notebooks") {
                    OutlineGroup(model.index.notebooks, children: \.children) { notebook in
                        Label(notebook.name, systemImage: "folder")
                            .tag(LibraryIndex.Filter.notebook(notebook.path))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
