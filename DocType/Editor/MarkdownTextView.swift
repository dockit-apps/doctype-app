// The editor's text view: a plain-text NSTextView on TextKit 2, configured for markdown.
// Reports focus changes and clicks on task checkboxes.

import AppKit

final class MarkdownTextView: NSTextView {
    /// Called with true/false when the editor gains or loses keyboard focus.
    var onFocusChange: (Bool) -> Void = { _ in }

    /// Called with the location of a task's "[ ]" when its checkbox is clicked.
    var onTaskBoxClick: (Int) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        guard let box = taskBoxLocation(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)  // so ⌘Z right after the click undoes it
        onTaskBoxClick(box)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if taskBoxLocation(at: convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() }
    }

    /// Where the "[ ]" of the checkbox under `point` (view coordinates) starts, if any.
    func taskBoxLocation(at point: NSPoint) -> Int? {
        guard let storage = textStorage, storage.length > 0, let window else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index - 1, index] where candidate >= 0 && candidate < storage.length {
            var box = NSRange()
            let line = (storage.string as NSString).lineRange(for: NSRange(location: candidate, length: 0))
            guard storage.attribute(EditorTheme.taskKey, at: candidate, longestEffectiveRange: &box, in: line) != nil
            else { continue }
            // The checkbox is drawn over the "[ ]" characters; allow a little slack around it.
            let screenRect = firstRect(forCharacterRange: box, actualRange: nil)
            let rect = convert(window.convertFromScreen(screenRect), from: nil)
            if rect.insetBy(dx: -3, dy: -2).contains(point) { return box.location }
        }
        return nil
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange(false) }
        return accepted
    }

    /// Builds a TextKit 2 text view inside a scroll view, ready for the editor.
    static func makeScrollableEditor() -> (NSScrollView, MarkdownTextView) {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.configureForMarkdown()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func configureForMarkdown() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        // Markdown and code need literal characters: no curly quotes, en dashes or auto-corrections.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = true

        font = EditorTheme.bodyFont
        textColor = .textColor
        typingAttributes = EditorTheme.baseAttributes
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 24, height: 20)

        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true

        #if DEBUG
        // Touching `layoutManager` anywhere silently drops the view back to TextKit 1.
        assert(textLayoutManager != nil, "Editor must use TextKit 2")
        NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: self, queue: .main
        ) { _ in
            assertionFailure("Editor switched to TextKit 1; something accessed NSTextView.layoutManager")
        }
        #endif
    }
}
