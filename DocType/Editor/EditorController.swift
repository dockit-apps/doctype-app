// Owns the editor's text view and the note open in it: loading, dirty tracking,
// autosave. Reacting when the note changes on disk is in +ExternalChanges.
//
// The text view holds only the note's body. The frontmatter (tags) is kept here
// and joined back on save, so the editor never shows YAML.

import AppKit
import DocTypeCore
import Observation
import os

@Observable
final class EditorController: NSObject, NSTextViewDelegate {
    static let autosaveDelay = Duration.seconds(1)

    /// Set while the note changed on disk and the editor has unsaved edits.
    /// Holds the disk text; autosave is paused until it's resolved (+ExternalChanges).
    var pendingDiskText: String?
    /// Tags from the open note's frontmatter (shown in the tag row). Set only
    /// here and in EditorController+Tags.
    var tags: [String] = []
    /// The text view, or a table cell's editor, has keyboard focus.
    private(set) var hasFocus = false
    /// The cursor is in a table (enables the table commands).
    var isInTable = false
    /// The table the cursor is in can get another column (see EditorTheme.maximumTableColumns).
    var canAddTableColumn = true
    /// A table cell is being edited (TableCellSession); line formats are off there.
    var isEditingTableCell = false
    /// The open note isn't UTF-8 text: it's shown but never changed or saved
    /// (saving would rewrite it as UTF-8, see NoteText).
    private(set) var isReadOnly = false

    @ObservationIgnored let scrollView: NSScrollView
    @ObservationIgnored let textView: MarkdownTextView
    @ObservationIgnored let styler = StyleApplier()
    @ObservationIgnored private let blockDecorations = BlockDecorations()
    @ObservationIgnored private(set) var path: String?
    @ObservationIgnored var frontmatter: Frontmatter?
    /// The note's full text as we last loaded it from or saved it to disk.
    @ObservationIgnored var lastSyncedText = ""
    @ObservationIgnored var isDirty = false
    @ObservationIgnored var autosaveTask: Task<Void, Never>?
    /// True while the open note's file is being renamed or moved.
    @ObservationIgnored private var isMoving = false
    @ObservationIgnored var library: Library?
    @ObservationIgnored var onError: (String) -> Void = { _ in }
    /// Called with a link's destination when it's ⌘-clicked.
    @ObservationIgnored var onOpenLink: (String) -> Void = { _ in }
    /// The editor's width when images were last sized, and a pending re-size.
    @ObservationIgnored var lastLayoutWidth: CGFloat = 0
    @ObservationIgnored var widthChangeTask: Task<Void, Never>?
    /// Editing a table cell in its own text view (set up in init).
    @ObservationIgnored private(set) var tableCells: TableCellSession!
    /// ↑ or ↓ was just pressed in the note: where the cursor was across, so a
    /// table it moves into opens the cell in that column.
    @ObservationIgnored var pendingVerticalMove: (x: CGFloat, up: Bool)?
    @ObservationIgnored private var textViewHasFocus = false
    @ObservationIgnored private var cellEditorHasFocus = false

    override init() {
        (scrollView, textView) = MarkdownTextView.makeScrollableEditor()
        super.init()
        textView.delegate = self
        styler.textView = textView
        textView.textStorage?.delegate = styler
        textView.textLayoutManager?.delegate = blockDecorations
        textView.onFocusChange = { [weak self] focused in
            self?.textViewHasFocus = focused
            self?.updateFocus()
            self?.selectionFocusDidChange()
        }
        textView.onTaskBoxClick = { [weak self] in self?.toggleTask(at: $0) }
        textView.onLinkClick = { [weak self] in self?.onOpenLink($0) }
        tableCells = TableCellSession(owner: self)
        setUpImages()
        setUpTables()
        let center = NotificationCenter.default
        for name: Notification.Name in [.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
            center.addObserver(self, selector: #selector(noteWillUndoOrRedo(_:)), name: name, object: nil)
        }
        for name: Notification.Name in [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.addObserver(self, selector: #selector(noteDidUndoOrRedo(_:)), name: name, object: nil)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(windowKeyDidChange(_:)), name: name, object: nil)
        }
    }

    @objc private func windowKeyDidChange(_ notification: Notification) {
        guard notification.object as? NSWindow === textView.window else { return }
        selectionFocusDidChange()
    }

    /// A selection in a table is drawn by the table, in a color that depends on
    /// focus. Once the focus change is done: the window's first responder
    /// changes after the view is told.
    private func selectionFocusDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.textView.textStorage else { return }
            self.styler.selectionFocusDidChange(in: storage)
        }
    }

    /// Called when a table cell's editor gains or loses keyboard focus.
    func cellEditorFocusChanged(_ focused: Bool) {
        cellEditorHasFocus = focused
        updateFocus()
    }

    private func updateFocus() {
        let focused = textViewHasFocus || cellEditorHasFocus
        if focused != hasFocus { hasFocus = focused }
    }

    func focusText() {
        textView.window?.makeFirstResponder(textView)
    }

    /// The note's full text as it would be written now: frontmatter + editor body.
    var currentText: String { (frontmatter?.raw ?? "") + textView.string }

    // MARK: - Opening and closing

    /// Saves the current note (if needed), then loads `path`.
    /// Returns false if the note couldn't be read.
    @discardableResult
    func open(_ path: String, focus: Bool = false) async -> Bool {
        guard path != self.path else { return true }
        await flush()
        guard let library else { return false }
        do {
            let state = DocTypeCore.signposter.beginInterval("Open note")
            defer { DocTypeCore.signposter.endInterval("Open note", state) }
            let note = await prepare(try await library.readNote(path), path: path)
            guard !Task.isCancelled else { return false }
            self.path = path
            show(note, keepingPosition: false)
            if focus { textView.window?.makeFirstResponder(textView) }
            return true
        } catch {
            return false
        }
    }

    /// Empties the editor (e.g. when the library changes). Unsaved text is saved first.
    func close() async {
        await flush()
        tableCells.cancel()
        path = nil
        frontmatter = nil
        tags = []
        lastSyncedText = ""
        isDirty = false
        setReadOnly(false)
        styler.imageContext = nil
        if let storage = textView.textStorage {
            styler.replaceDocument(in: storage, text: "", blockMap: BlockMap(), spans: [],
                                   selection: NSRange(location: 0, length: 0))
        }
        textView.undoManager?.removeAllActions()
    }

    // MARK: - Saving

    /// Saves everything before leaving the note or quitting. A pending conflict is
    /// resolved as "Use Disk Version": your edits go to a conflict copy, nothing is lost.
    func flush() async {
        if pendingDiskText != nil { await resolveConflict(.useDiskVersion) }
        await save()
    }

    /// Runs a rename or move of the open note's file. Saves first, then holds
    /// autosave until the move is done, so nothing gets written to the old path.
    /// `move` returns the note's new path.
    func whileMoving(_ move: () async throws -> String) async throws {
        await flush()
        isMoving = true
        defer {
            isMoving = false
            if isDirty { scheduleAutosave() }
        }
        path = try await move()
    }

    /// Closes the note without saving, e.g. after it was moved to the Trash.
    func discard() async {
        isDirty = false
        pendingDiskText = nil
        await close()
    }

    /// Writes the note if it has unsaved changes. Paused while a conflict is
    /// pending or the file is being moved.
    func save() async {
        autosaveTask?.cancel()
        guard isDirty, !isReadOnly, pendingDiskText == nil, !isMoving, let path, let library else { return }
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

    // MARK: - Showing text

    /// A note's text split and styled, ready to put on screen.
    struct PreparedNote {
        let text: String
        let frontmatter: Frontmatter?
        let body: String
        let blockMap: BlockMap
        let spans: [StyleSpan]
        let images: ImageContext?
        let isReadOnly: Bool
    }

    /// Splits off the frontmatter, styles the body and measures its images, all
    /// off the main thread.
    func prepare(_ note: NoteText, path: String) async -> PreparedNote {
        let text = note.text
        let (frontmatter, body) = Frontmatter.split(text)
        let bodyText = String(body)
        let styled = await MarkdownStyler.styleDocument(bodyText)
        let images = imageContext(forNote: path)
        await measureImages(in: styled.spans, context: images)
        return PreparedNote(text: text, frontmatter: frontmatter, body: bodyText,
                            blockMap: styled.blockMap, spans: styled.spans, images: images, isReadOnly: !note.isUTF8)
    }

    /// Puts a prepared note into the editor without registering undo.
    /// When reloading the same note, the caret and scroll position stay put.
    func show(_ note: PreparedNote, keepingPosition: Bool) {
        let scrollOrigin = scrollView.contentView.bounds.origin
        let length = (note.body as NSString).length
        let selection = keepingPosition
            ? NSRange(location: min(textView.selectedRange().location, length), length: 0)
            : NSRange(location: 0, length: 0)
        tableCells.cancel()

        frontmatter = note.frontmatter
        tags = note.frontmatter?.tags ?? []
        lastSyncedText = note.text
        isDirty = false
        autosaveTask?.cancel()
        setReadOnly(note.isReadOnly)
        styler.imageContext = note.images
        if let storage = textView.textStorage {
            styler.replaceDocument(in: storage, text: note.body, blockMap: note.blockMap, spans: note.spans,
                                   selection: selection)
        }
        // Clearing makes ⌘Z never reach text from another note or version.
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(selection)
        if keepingPosition {
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    private func setReadOnly(_ readOnly: Bool) {
        if readOnly != isReadOnly { isReadOnly = readOnly }
        textView.isEditable = !readOnly
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        isDirty = true
        if let storage = textView.textStorage { styler.applyPendingStyles(in: storage) }
        moveCursorOutOfTables()
        scheduleAutosave()
    }

    /// The cursor moved: show the markdown syntax on its line, hide it elsewhere.
    func textViewDidChangeSelection(_ notification: Notification) {
        if let storage = textView.textStorage { styler.selectionDidChange(in: storage) }
        updateIsInTable()
        moveCursorOutOfTables()
    }

    func scheduleAutosave() {
        autosaveTask?.cancel()
        guard pendingDiskText == nil else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }
}
