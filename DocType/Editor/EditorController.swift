// Owns the editor's text view and the note open in it: loading, dirty tracking,
// autosave, and reacting when the note changes on disk (see ExternalChangePolicy).
//
// The text view holds only the note's body. The frontmatter (tags) is kept here
// and joined back on save, so the editor never shows YAML.

import AppKit
import DocTypeCore
import Observation

@Observable
final class EditorController: NSObject, NSTextViewDelegate {
    static let autosaveDelay = Duration.seconds(1)

    /// Set while the note changed on disk and the editor has unsaved edits.
    /// Holds the disk text; autosave is paused until it's resolved.
    private(set) var pendingDiskText: String?

    @ObservationIgnored let scrollView: NSScrollView
    @ObservationIgnored let textView: MarkdownTextView
    @ObservationIgnored private(set) var path: String?
    @ObservationIgnored private var frontmatter: Frontmatter?
    /// The note's full text as we last loaded it from or saved it to disk.
    @ObservationIgnored private var lastSyncedText = ""
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored var library: Library?
    @ObservationIgnored var onError: (String) -> Void = { _ in }

    override init() {
        (scrollView, textView) = MarkdownTextView.makeScrollableEditor()
        super.init()
        textView.delegate = self
    }

    /// The note's full text as it would be written now: frontmatter + editor body.
    private var currentText: String { (frontmatter?.raw ?? "") + textView.string }

    // MARK: - Opening and closing

    /// Saves the current note (if needed), then loads `path`.
    /// Returns false if the note couldn't be read.
    @discardableResult
    func open(_ path: String, focus: Bool = false) async -> Bool {
        guard path != self.path else { return true }
        await flush()
        guard let library else { return false }
        do {
            let text = try await library.read(path)
            guard !Task.isCancelled else { return false }
            self.path = path
            load(text, keepingPosition: false)
            if focus { textView.window?.makeFirstResponder(textView) }
            return true
        } catch {
            return false
        }
    }

    /// Empties the editor (e.g. when the library changes). Unsaved text is saved first.
    func close() async {
        await flush()
        path = nil
        frontmatter = nil
        lastSyncedText = ""
        textView.string = ""
        textView.undoManager?.removeAllActions()
    }

    // MARK: - Saving

    /// Saves everything before leaving the note or quitting. A pending conflict is
    /// resolved as "Use Disk Version": your edits go to a conflict copy, nothing is lost.
    func flush() async {
        if pendingDiskText != nil { await resolveConflict(.useDiskVersion) }
        await save()
    }

    /// Writes the note if it has unsaved changes. Paused while a conflict is pending.
    func save() async {
        autosaveTask?.cancel()
        guard isDirty, pendingDiskText == nil, let path, let library else { return }
        let text = currentText
        isDirty = false
        lastSyncedText = text
        do {
            try await library.save(path, text: text)
        } catch {
            isDirty = true
            onError("Couldn't save “\(path)”: \(error.localizedDescription)")
        }
    }

    // MARK: - External changes

    /// Called when the open note may have changed on disk.
    func noteChangedOnDisk() async {
        guard let path, let library else { return }
        guard let diskText = try? await library.read(path) else {
            await noteRemovedFromDisk()
            return
        }
        guard path == self.path else { return }  // switched notes while reading
        switch ExternalChangePolicy.action(
            diskText: diskText, lastSyncedText: lastSyncedText,
            hasUnsavedEdits: isDirty, conflictPending: pendingDiskText != nil
        ) {
        case .ignore:
            break
        case .reload:
            load(diskText, keepingPosition: true)
        case .showConflict:
            autosaveTask?.cancel()
            pendingDiskText = diskText
        }
    }

    /// The open note was deleted or moved away by another program. Unsaved edits
    /// are kept as a conflict copy; then the editor closes.
    private func noteRemovedFromDisk() async {
        if let path, let library, isDirty || pendingDiskText != nil {
            do {
                try await library.saveConflictCopy(of: path, text: currentText)
            } catch {
                onError("Couldn't keep your edits to “\(path)”: \(error.localizedDescription)")
                return  // keep the text in the editor rather than lose it
            }
        }
        isDirty = false
        pendingDiskText = nil
        await close()
    }

    /// Applies the banner choice: first the conflict copy, then the final text.
    func resolveConflict(_ choice: ExternalChangePolicy.Choice) async {
        guard let diskText = pendingDiskText, let path, let library else { return }
        let resolution = ExternalChangePolicy.resolve(choice, editorText: currentText, diskText: diskText)
        do {
            try await library.saveConflictCopy(of: path, text: resolution.copyText)
        } catch {
            onError("Couldn't save a conflict copy of “\(path)”: \(error.localizedDescription)")
            return  // banner stays; nothing has been discarded
        }
        pendingDiskText = nil
        switch choice {
        case .keepMine:
            lastSyncedText = diskText
            isDirty = true
            await save()
        case .useDiskVersion:
            load(resolution.finalText, keepingPosition: true)
        }
    }

    // MARK: - Showing text

    /// Puts a note's text into the editor without registering undo.
    /// When reloading the same note, the caret and scroll position stay put.
    private func load(_ text: String, keepingPosition: Bool) {
        let (frontmatter, body) = Frontmatter.split(text)
        let selection = textView.selectedRange()
        let scrollOrigin = scrollView.contentView.bounds.origin

        self.frontmatter = frontmatter
        lastSyncedText = text
        isDirty = false
        autosaveTask?.cancel()
        textView.string = String(body)
        // Clearing makes ⌘Z never reach text from another note or version.
        textView.undoManager?.removeAllActions()

        if keepingPosition {
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        isDirty = true
        autosaveTask?.cancel()
        guard pendingDiskText == nil else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }
}
