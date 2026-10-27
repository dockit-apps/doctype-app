// Owns the editor's text view and the note open in it: loading, dirty tracking and autosave.
//
// The text view holds only the note's body. The frontmatter (tags) is kept here
// and joined back on save, so the editor never shows YAML.

import AppKit
import DocTypeCore

final class EditorController: NSObject, NSTextViewDelegate {
    static let autosaveDelay = Duration.seconds(1)

    let scrollView: NSScrollView
    let textView: MarkdownTextView

    private(set) var path: String?
    private var frontmatter: Frontmatter?
    private var isDirty = false
    private var autosaveTask: Task<Void, Never>?
    var library: Library?
    var onError: (String) -> Void = { _ in }

    override init() {
        (scrollView, textView) = MarkdownTextView.makeScrollableEditor()
        super.init()
        textView.delegate = self
    }

    /// Saves the current note (if needed), then loads `path`.
    /// Returns false if the note couldn't be read.
    @discardableResult
    func open(_ path: String, focus: Bool = false) async -> Bool {
        guard path != self.path else { return true }
        await save()
        guard let library else { return false }
        do {
            let text = try await library.read(path)
            guard !Task.isCancelled else { return false }
            show(text, for: path)
            if focus { textView.window?.makeFirstResponder(textView) }
            return true
        } catch {
            return false
        }
    }

    /// Empties the editor (e.g. when the library changes). Unsaved text is saved first.
    func close() async {
        await save()
        path = nil
        frontmatter = nil
        textView.string = ""
        textView.undoManager?.removeAllActions()
    }

    /// Writes the note if it has unsaved changes. Safe to call any time.
    func save() async {
        autosaveTask?.cancel()
        guard isDirty, let path, let library else { return }
        let text = (frontmatter?.raw ?? "") + textView.string
        isDirty = false
        do {
            try await library.save(path, text: text)
        } catch {
            isDirty = true
            onError("Couldn't save “\(path)”: \(error.localizedDescription)")
        }
    }

    private func show(_ text: String, for path: String) {
        let (frontmatter, body) = Frontmatter.split(text)
        self.path = path
        self.frontmatter = frontmatter
        isDirty = false
        // Setting `string` doesn't register undo; clearing makes ⌘Z never reach the previous note.
        textView.string = String(body)
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        isDirty = true
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }
}
