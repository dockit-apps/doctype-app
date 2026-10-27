// App-wide UI state: the open library, its latest index snapshot, and what is selected.
// Views read from here and call its methods; the file work happens in DocTypeCore's Library actor.

import DocTypeCore
import Foundation
import Observation

@Observable
final class AppModel {
    private(set) var libraryURL: URL?
    private(set) var index = LibraryIndex()
    private(set) var isScanning = false
    var errorMessage: String?

    var sidebarSelection: LibraryIndex.Filter? = .all
    var selectedNotePath: String?

    private var library: Library?
    private var updatesTask: Task<Void, Never>?

    init() {
        if let url = LibraryBookmark.load() { open(url) }
    }

    /// Notes for the current sidebar selection, newest first.
    var visibleNotes: [NoteSummary] {
        index.notes(matching: sidebarSelection ?? .all)
    }

    var selectedNote: NoteSummary? {
        selectedNotePath.flatMap { index.notes[$0] }
    }

    func chooseLibrary(_ url: URL) {
        LibraryBookmark.save(url)
        open(url)
    }

    private func open(_ url: URL) {
        let library = Library(root: url)
        self.library = library
        libraryURL = url
        index = LibraryIndex()
        sidebarSelection = .all
        selectedNotePath = nil

        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await snapshot in library.updates {
                self?.index = snapshot
            }
        }
        Task {
            isScanning = true
            defer { isScanning = false }
            do {
                try await library.scan()
            } catch {
                errorMessage = "Couldn't read the library: \(error.localizedDescription)"
            }
        }
    }
}
