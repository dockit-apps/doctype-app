// The editor's text view: a plain-text NSTextView on TextKit 2, configured for markdown.
// Reports focus changes, clicks on task checkboxes, ⌘-clicks on links, and
// drags of an image's resize handle.

import AppKit

final class MarkdownTextView: NSTextView {
    /// Called with true/false when the editor gains or loses keyboard focus.
    var onFocusChange: (Bool) -> Void = { _ in }

    /// Called with the location of a task's "[ ]" when its checkbox is clicked.
    var onTaskBoxClick: (Int) -> Void = { _ in }

    /// Called with a link's destination when it's ⌘-clicked.
    var onLinkClick: (String) -> Void = { _ in }

    /// Called while an image's resize handle is dragged (with the image syntax's
    /// range and the new width), and once more with `isFinished` on release.
    var onImageResize: (_ range: NSRange, _ width: CGFloat, _ isFinished: Bool) -> Void = { _, _, _ in }

    /// The image being resized: its syntax, width and where the drag started.
    private var resizing: (range: NSRange, startWidth: CGFloat, startX: CGFloat, width: CGFloat)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), let destination = linkDestination(at: point) {
            onLinkClick(destination)
            return
        }
        if let hit = imageHit(at: point) {
            window?.makeFirstResponder(self)
            if hit.image.isSelected, Self.resizeZone(of: hit.frame).contains(point) {
                resizing = (hit.range, hit.frame.width, point.x, hit.frame.width)
            } else if event.clickCount == 2 {
                NSWorkspace.shared.open(hit.image.url)
            } else {
                // Selects the image: the cursor goes to the end of its syntax, which shows the handle.
                setSelectedRange(NSRange(location: hit.range.upperBound, length: 0))
            }
            return
        }
        guard let box = taskBoxLocation(at: point) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)  // so ⌘Z right after the click undoes it
        onTaskBoxClick(box)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = resizing else { return super.mouseDragged(with: event) }
        let x = convert(event.locationInWindow, from: nil).x
        let maxWidth = (textContainer?.size.width ?? bounds.width) - 2 * (textContainer?.lineFragmentPadding ?? 0)
        let width = min(max(current.startWidth + x - current.startX, 32), maxWidth).rounded()
        guard width != current.width else { return }
        resizing?.width = width
        onImageResize(current.range, width, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = resizing else { return super.mouseUp(with: event) }
        resizing = nil
        onImageResize(finished.range, finished.width, true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCursor(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    /// Pressing or releasing ⌘ over a link switches between the hand and the I-beam.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else { return }
        if !updateCursor(at: point, modifiers: event.modifierFlags) { NSCursor.iBeam.set() }
    }

    /// Shows the pointing hand over checkboxes, and over links while ⌘ is held;
    /// an arrow over images, and a resize cursor over a selected image's handle.
    @discardableResult
    private func updateCursor(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        if let hit = imageHit(at: point) {
            if hit.image.isSelected, Self.resizeZone(of: hit.frame).contains(point) {
                NSCursor.frameResize(position: .bottomRight, directions: .all).set()
            } else {
                NSCursor.arrow.set()
            }
            return true
        }
        let overLink = modifiers.contains(.command) && linkDestination(at: point) != nil
        guard overLink || taskBoxLocation(at: point) != nil else { return false }
        NSCursor.pointingHand.set()
        return true
    }

    // MARK: - Images

    /// Where dragging resizes an image: its corner handle, and its right edge.
    private static func resizeZone(of frame: CGRect) -> CGRect {
        DecoratedLayoutFragment.resizeHandle(of: frame).insetBy(dx: -5, dy: -5)
            .union(CGRect(x: frame.maxX - 6, y: frame.minY, width: 12, height: frame.height))
    }

    /// The image under `point` (view coordinates): its attribute, the range of its
    /// syntax in the document, and where it's drawn.
    func imageHit(at point: NSPoint) -> (image: ImageAttribute, range: NSRange, frame: CGRect)? {
        guard let layout = textLayoutManager else { return nil }
        let origin = textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = layout.textLayoutFragment(for: inContainer) as? DecoratedLayoutFragment else { return nil }
        let fragmentOrigin = fragment.layoutFragmentFrame.origin
        for (mark, frame) in fragment.imageFrames {
            let inView = frame.offsetBy(dx: fragmentOrigin.x + origin.x, dy: fragmentOrigin.y + origin.y)
            guard Self.resizeZone(of: inView).union(inView).contains(point) else { continue }
            let paragraphStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
            return (mark.image, NSRange(location: paragraphStart + mark.range.location, length: mark.range.length), inView)
        }
        return nil
    }

    /// Where the "[ ]" of the checkbox under `point` (view coordinates) starts, if any.
    func taskBoxLocation(at point: NSPoint) -> Int? {
        // The checkbox is drawn over the "[ ]" characters; allow a little slack around it.
        hit(EditorTheme.taskKey, at: point, slack: CGSize(width: 3, height: 2))?.range.location
    }

    /// The destination of the link under `point`, if any.
    func linkDestination(at point: NSPoint) -> String? {
        hit(EditorTheme.linkKey, at: point, slack: .zero)?.value as? String
    }

    /// The run of `key` under `point` (view coordinates): its value and range.
    private func hit(_ key: NSAttributedString.Key, at point: NSPoint, slack: CGSize) -> (value: Any, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0, let window else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index - 1, index] where candidate >= 0 && candidate < storage.length {
            var run = NSRange()
            let line = (storage.string as NSString).lineRange(for: NSRange(location: candidate, length: 0))
            guard let value = storage.attribute(key, at: candidate, longestEffectiveRange: &run, in: line) else { continue }
            // The clicked character itself (not the run's first rect: a link can wrap).
            let screenRect = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            let character = convert(window.convertFromScreen(screenRect), from: nil)
            if character.insetBy(dx: -slack.width, dy: -slack.height).contains(point) {
                return (value, run)
            }
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
