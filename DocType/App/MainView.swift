// The three-pane layout: sidebar → note list → editor.

import SwiftUI

struct MainView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("All Notes", systemImage: "note.text")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            ContentUnavailableView("No Notes", systemImage: "note.text")
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil")
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
