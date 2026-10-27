// The editor's text view: a plain-text NSTextView on TextKit 2, configured for markdown.
// Reports focus changes; later phases add task-marker clicks here.

import AppKit

final class MarkdownTextView: NSTextView {
    /// Called with true/false when the editor gains or loses keyboard focus.
    var onFocusChange: (Bool) -> Void = { _ in }

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
