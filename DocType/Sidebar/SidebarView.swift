// Sidebar: "All Notes", the notebook folder tree and the tags with their note
// counts. Selecting an item filters the note list.

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

            if !model.tagCounts.isEmpty {
                Section("Tags") {
                    ForEach(model.tagCounts, id: \.name) { tag in
                        Label(tag.name, systemImage: "number")
                            .badge(tag.count)
                            .accessibilityValue(tag.count == 1 ? "1 note" : "\(tag.count) notes")
                            .tag(LibraryIndex.Filter.tag(tag.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
