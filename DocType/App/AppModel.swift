// App-wide UI state: the open library, its latest index snapshot, what is selected,
// and the editor. Views read from here and call its methods; file work happens in
// DocTypeCore's Library actor.

import AppKit
import DocTypeCore
import Observation
import SwiftUI

@Observable
final class AppModel {
    private(set) var libraryURL: URL?
    private(set) var index = LibraryIndex() {
        didSet {
            refreshVisibleNotes()
            tagCounts = index.tagCounts()
        }
    }
    /// Every tag in the library with its note count (the sidebar's Tags section).
    private(set) var tagCounts: [TagCount] = []
    private(set) var isScanning = false
    /// The library folder was moved or deleted while open.
    private(set) var isLibraryMissing = false
    var errorMessage: String?

    var isChoosingLibrary = false
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// The palette currently shown, if any.
    private(set) var palette: Palette?
    /// Incremented to ask the note header to focus the title field.
    var titleFocusRequest = 0
    /// The notebook being renamed (path) and the name typed so far.
    var notebookBeingRenamed: String?
    var notebookNameDraft = ""

    var sidebarSelection: LibraryIndex.Filter? = .all {
        didSet { refreshVisibleNotes() }
    }
    /// Notes for the current sidebar selection, newest first. Cached so the list
    /// doesn't re-sort the whole library every time SwiftUI reads it.
    private(set) var visibleNotes: [NoteSummary] = []
    var selectedNotePath: String?

    @ObservationIgnored let editor = EditorController()
    @ObservationIgnored private(set) lazy var commands = CommandRunner(model: self)
    /// Where keyboard focus was before the palette opened, to put it back after.
    @ObservationIgnored private weak var focusBeforePalette: NSResponder?
    @ObservationIgnored var focusTitleOnNextOpen = false
    @ObservationIgnored private(set) var library: Library?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var hasOpenedANote = false

    private static let lastOpenNoteKey = "lastOpenNote"

    init() {
        editor.onError = { [weak self] message in self?.errorMessage = message }
        // When the app only hosts unit tests, don't open (and watch) the user's library.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTestHost, let url = LibraryBookmark.load() {
            open(url, restoring: UserDefaults.standard.string(forKey: Self.lastOpenNoteKey))
        }
    }

    private func refreshVisibleNotes() {
        visibleNotes = index.notes(matching: sidebarSelection ?? .all)
    }

    var hasUsableLibrary: Bool { library != nil && !isLibraryMissing }

    // MARK: - Commands

    func showCommandPalette() {
        let items = CommandID.allCases
            .filter { $0 != .showCommandPalette && commands.isEnabled($0) }
            .map { command in
                PaletteItem(
                    id: command.rawValue, title: command.title,
                    detail: command.info.defaultShortcuts.first?.displayString,
                    action: { [weak self] in self?.commands.run(command) }
                )
            }
        showPalette(Palette(placeholder: "Type a command", items: items))
    }

    func showPalette(_ palette: Palette) {
        if self.palette == nil {
            focusBeforePalette = NSApp.keyWindow?.firstResponder
            // Let go of the editor's focus, so typing goes to the palette's field.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        self.palette = palette
    }

    /// Closes the palette and runs the chosen item after focus is back where it was.
    func choosePaletteItem(_ item: PaletteItem) {
        dismissPalette()
        item.action()
    }

    func dismissPalette() {
        palette = nil
        if let responder = focusBeforePalette {
            NSApp.keyWindow?.makeFirstResponder(responder)
        }
        focusBeforePalette = nil
    }

    func toggleSidebar() {
        columnVisibility = columnVisibility == .all ? .doubleColumn : .all
    }

    /// Creates `Untitled.md` in the selected notebook (or the library root), opens it
    /// and puts the cursor in the title field. While a tag is selected, the note
    /// gets that tag, so it shows up in the list you're looking at.
    func createNote() async {
        guard let library else { return }
        do {
            let path = try await library.createNote(in: selectedNotebook, tags: selectedTag.map { [$0] } ?? [])
            focusTitleOnNextOpen = true
            selectedNotePath = path
        } catch {
            errorMessage = "Couldn't create a note: \(error.localizedDescription)"
        }
    }

    // MARK: - Library

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
        let focusTitle = focusTitleOnNextOpen
        focusTitleOnNextOpen = false
        if await editor.open(path, focus: isLaunchRestore && !focusTitle) {
            hasOpenedANote = true
            UserDefaults.standard.set(path, forKey: Self.lastOpenNoteKey)
            if focusTitle { titleFocusRequest += 1 }
            if isLaunchRestore { LaunchTimer.logEditable() }
        } else if !Task.isCancelled, selectedNotePath == path {
            selectedNotePath = nil  // the note no longer exists
        }
    }

    /// Saves any unsaved text. Called before quitting and when the app loses focus.
    func saveAll() async {
        await editor.save()
    }

    /// Reacts to changes other programs made in the library folder.
    private func handle(_ change: Library.Change) async {
        switch change {
        case .libraryMissing:
            isLibraryMissing = true
        case .notesChanged(let paths):
            // An empty set means a full rescan: the open note may have changed too.
            guard let openPath = editor.path, paths.isEmpty || paths.contains(openPath) else { return }
            await editor.noteChangedOnDisk()
            if editor.path == nil, selectedNotePath == openPath {
                selectedNotePath = nil  // the note was deleted or moved away
            }
        }
    }

    private func open(_ url: URL, restoring notePath: String?) {
        let library = Library(root: url)
        self.library = library
        editor.library = library
        libraryURL = url
        isLibraryMissing = false
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
        changesTask?.cancel()
        changesTask = Task { [weak self] in
            for await change in library.changes {
                await self?.handle(change)
            }
        }
        Task {
            isScanning = true
            defer { isScanning = false }
            do {
                // Watch first, so nothing that happens during the scan is missed.
                await library.startWatching()
                try await library.scan()
            } catch {
                errorMessage = "Couldn't read the library: \(error.localizedDescription)"
            }
        }
    }
}
