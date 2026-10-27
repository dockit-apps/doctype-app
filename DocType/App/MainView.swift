// The three-pane layout: sidebar → note list → editor, plus first-launch onboarding.

import DocTypeCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 800, minHeight: 500)
        .fileImporter(isPresented: $model.isChoosingLibrary, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.chooseLibrary(url) }
        }
        .overlay(alignment: .top) { paletteOverlay }
        .animation(.snappy(duration: 0.15), value: model.palette != nil)
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
                Button("Choose Library…") { model.commands.run(.chooseLibrary) }
                    .buttonStyle(.glassProminent)
            }
        } else if model.isLibraryMissing {
            ContentUnavailableView {
                Label("Library Not Found", systemImage: "folder.badge.questionmark")
            } description: {
                Text("The library folder was moved or deleted.")
            } actions: {
                Button("Choose Library…") { model.commands.run(.chooseLibrary) }
                    .buttonStyle(.glassProminent)
            }
        } else if let path = model.selectedNotePath {
            EditorView(controller: model.editor)
                .overlay(alignment: .bottom) {
                    if model.editor.pendingDiskText != nil {
                        ConflictBanner(
                            onKeepMine: { Task { await model.editor.resolveConflict(.keepMine) } },
                            onUseDiskVersion: { Task { await model.editor.resolveConflict(.useDiskVersion) } }
                        )
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: model.editor.pendingDiskText != nil)
                .navigationTitle(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                .task(id: path) { await model.openSelectedNote() }
        } else {
            ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil")
        }
    }

    @ViewBuilder private var paletteOverlay: some View {
        if let palette = model.palette {
            ZStack(alignment: .top) {
                // Clicking anywhere outside the palette closes it.
                Color.black.opacity(0.001)
                    .onTapGesture { model.dismissPalette() }
                CommandPaletteView(
                    palette: palette,
                    onChoose: { model.choosePaletteItem($0) },
                    onDismiss: { model.dismissPalette() }
                )
                .padding(.top, 60)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
