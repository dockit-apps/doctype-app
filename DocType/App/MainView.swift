// The three-pane layout: sidebar → note list → editor, plus first-launch onboarding.

import DocTypeCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var isChoosingLibrary = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 800, minHeight: 500)
        .fileImporter(isPresented: $isChoosingLibrary, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.chooseLibrary(url) }
        }
        .alert("Something went wrong", isPresented: errorIsPresented) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        if model.libraryURL == nil {
            ContentUnavailableView {
                Label("Choose a Library", systemImage: "folder")
            } description: {
                Text("DocType keeps your notes as Markdown files in a folder you choose.")
            } actions: {
                Button("Choose Library…") { isChoosingLibrary = true }
                    .buttonStyle(.glassProminent)
            }
        } else if let path = model.selectedNotePath {
            EditorView(controller: model.editor)
                .navigationTitle(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                .task(id: path) { await model.openSelectedNote() }
        } else {
            ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
