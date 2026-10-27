// App-wide UI state: the open library, its latest index snapshot, what is selected,
// and the editor. Views read from here and call its methods; file work happens in
// DocTypeCore's Library actor.

import DocTypeCore
import Foundation
import Observation

@Observable
final class AppModel {
    private(set) var libraryURL: URL?
    private(set) var index = LibraryIndex() {
        didSet { refreshVisibleNotes() }
    }
    private(set) var isScanning = false
    var errorMessage: String?

    var sidebarSelection: LibraryIndex.Filter? = .all {
        didSet { refreshVisibleNotes() }
    }
    /// Notes for the current sidebar selection, newest first. Cached so the list
    /// doesn't re-sort the whole library every time SwiftUI reads it.
    private(set) var visibleNotes: [NoteSummary] = []
    var selectedNotePath: String?

    @ObservationIgnored let editor = EditorController()
    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var hasOpenedANote = false

    private static let lastOpenNoteKey = "lastOpenNote"

    init() {
        editor.onError = { [weak self] message in self?.errorMessage = message }
        if let url = LibraryBookmark.load() {
            open(url, restoring: UserDefaults.standard.string(forKey: Self.lastOpenNoteKey))
        }
    }

    private func refreshVisibleNotes() {
        visibleNotes = index.notes(matching: sidebarSelection ?? .all)
    }

    func chooseLibrary(_ url: URL) {
        LibraryBookmark.save(url)
        UserDefaults.standard.removeObject(forKey: Self.lastOpenNoteKey)
        Task {
            await editor.close()
            open(url, restoring: nil)
        }
    }

    /// Loads the selected note into the editor. On the first open after launch the
    /// editor also takes keyboard focus, so you can type straight away.
    func openSelectedNote() async {
        guard let path = selectedNotePath else { return }
        let isLaunchRestore = !hasOpenedANote
        if await editor.open(path, focus: isLaunchRestore) {
            hasOpenedANote = true
            UserDefaults.standard.set(path, forKey: Self.lastOpenNoteKey)
            if isLaunchRestore { LaunchTimer.logEditable() }
        } else if !Task.isCancelled, selectedNotePath == path {
            selectedNotePath = nil  // the note no longer exists
        }
    }

    /// Saves any unsaved text. Called before quitting and when the app loses focus.
    func saveAll() async {
        await editor.save()
    }

    private func open(_ url: URL, restoring notePath: String?) {
        let library = Library(root: url)
        self.library = library
        editor.library = library
        libraryURL = url
        index = LibraryIndex()
        sidebarSelection = .all
        // The last note opens right away; it doesn't wait for the scan.
        selectedNotePath = notePath

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
