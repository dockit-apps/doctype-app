// The editor's text view: a plain-text NSTextView on TextKit 2, configured for markdown.
// Reports focus changes, clicks on task checkboxes, ⌘-clicks on links, and
// drags of an image's resize handle.

import AppKit
import DocTypeCore

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

    /// Called when a table's "+" button is clicked or a table item is chosen from
    /// the context menu: the operation, and a location in the row/cell it's for.
    var onTableOperation: (_ operation: TableOperation, _ location: Int) -> Void = { _, _ in }

    private static let verticalInset: CGFloat = 20
    private static let minimumHorizontalInset: CGFloat = 24
    private static let lineFragmentPadding: CGFloat = 5

    /// The widest the text gets: 70 digit widths of the body font (CSS's
    /// `70ch`), a comfortable line length. Wider windows center it.
    static let textColumnWidth = (("0" as NSString).size(withAttributes: [.font: EditorTheme.bodyFont]).width * 70).rounded()
    /// Where the text starts in a window too narrow to center it: the note
    /// header uses the same, so title, tags and text line up.
    static let minimumTextMargin = minimumHorizontalInset + lineFragmentPadding

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let column = Self.textColumnWidth + 2 * Self.lineFragmentPadding
        let inset = max(Self.minimumHorizontalInset, ((newSize.width - column) / 2).rounded(.down))
        if textContainerInset.width != inset { textContainerInset.width = inset }
    }
    /// Extra room under the text (see StyleApplier.updateTrailingSpace). The
    /// inset applies above and below, so half goes in it and the origin moves up
    /// by that half: only the bottom grows.
    var trailingSpace: CGFloat = 0 {
        didSet {
            guard trailingSpace != oldValue else { return }
            textContainerInset.height = Self.verticalInset + halfTrailingSpace
        }
    }
    /// Whole points, so the text isn't drawn on half pixels.
    private var halfTrailingSpace: CGFloat { (trailingSpace / 2).rounded(.up) }

    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        origin.y -= halfTrailingSpace
        return origin
    }

    /// Called with files dropped or pasted into the editor and where they go.
    var onAttach: (_ items: [IncomingAttachment], _ location: Int) -> Void = { _, _ in }

    /// Called with a table cell's location (just after its opening pipe) when
    /// it's clicked; the cell editor takes over the click.
    var onTableCellClick: (_ cell: Int, _ event: NSEvent) -> Void = { _, _ in }

    /// The image being resized: its syntax, width and where the drag started.
    private var resizing: (range: NSRange, startWidth: CGFloat, startX: CGFloat, width: CGFloat)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), let destination = linkDestination(at: point) {
            onLinkClick(destination)
            return
        }
        if let button = tableButtonHit(at: point) {
            window?.makeFirstResponder(self)
            onTableOperation(button.operation, button.location)
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
        if let cell = tableCellHit(at: point) {
            onTableCellClick(cell.location, event)
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
        if tableButtonHit(at: point) != nil {
            NSCursor.pointingHand.set()
            return true
        }
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

    // MARK: - Tables

    /// The table "+" button under `point`: what it does and a location in the row it's on.
    func tableButtonHit(at point: NSPoint) -> (operation: TableOperation, location: Int)? {
        guard let (fragment, inFragment) = decoratedFragment(at: point) else { return nil }
        guard let button = fragment.tableButtons.first(where: { $0.frame.insetBy(dx: -3, dy: -3).contains(inFragment) })
        else { return nil }
        guard let layout = textLayoutManager else { return nil }
        let rowStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        var lineEnd = 0
        (string as NSString).getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: NSRange(location: rowStart, length: 0))
        switch button.button {
        case .addRow: return (.addRowBelow, rowStart)
        case .addColumn: return (.addColumnRight, max(rowStart, lineEnd - 1))  // the last cell
        }
    }

    /// The table cell under `point`: where it starts in the text (just after its
    /// opening pipe) and its area, grid lines to grid lines (view coordinates).
    func tableCellHit(at point: NSPoint) -> (location: Int, frame: CGRect)? {
        guard let (fragment, inFragment) = decoratedFragment(at: point), let row = fragment.tableRow,
              !row.isDelimiter, inFragment.y >= 0, inFragment.y <= row.height, let layout = textLayoutManager
        else { return nil }
        let rowStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        let origin = fragmentOrigin(fragment)
        for (index, cell) in row.cells.enumerated() {
            let column = min(index, row.columnLines.count - 2)
            let area = CGRect(x: row.columnLines[column], y: 0,
                              width: row.columnLines[column + 1] - row.columnLines[column], height: row.height)
            guard area.contains(inFragment) else { continue }
            return (rowStart + cell.range.location, area.offsetBy(dx: origin.x, dy: origin.y))
        }
        return nil
    }

    /// Where the text of the table cell starting at `location` goes (view
    /// coordinates), and the cell's layout. Lays the row out first if needed.
    func tableCellTextFrame(at location: Int) -> (frame: CGRect, cell: TableRowLayout.Cell)? {
        guard let layout = textLayoutManager, let start = layOutTable(through: location),
              let fragment = layout.textLayoutFragment(for: start) as? DecoratedLayoutFragment,
              let row = fragment.tableRow else { return nil }
        let rowStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        guard let cell = row.cells.first(where: { rowStart + $0.range.location == location }) else { return nil }
        let origin = fragmentOrigin(fragment)
        return (cell.frame.offsetBy(dx: origin.x, dy: origin.y), cell)
    }

    /// The cell of the table row holding `location` that is under `x` (view
    /// coordinates), by where it starts in the text.
    func tableCell(inRowAt location: Int, x: CGFloat) -> Int? {
        guard let layout = textLayoutManager, let start = layOutTable(through: location),
              let fragment = layout.textLayoutFragment(for: start) as? DecoratedLayoutFragment,
              let row = fragment.tableRow, !row.cells.isEmpty else { return nil }
        let rowStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        let inRow = x - fragmentOrigin(fragment).x
        let column = (row.columnLines.indices.dropFirst().first { inRow < row.columnLines[$0] } ?? row.columnLines.count - 1) - 1
        return rowStart + row.cells[min(max(column, 0), row.cells.count - 1)].range.location
    }

    /// Where the cursor is across, in view coordinates.
    var caretX: CGFloat {
        guard let window else { return 0 }
        let onScreen = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
        return convert(window.convertFromScreen(onScreen), from: nil).minX
    }

    /// Lays out the table row at `location` where it's drawn, and returns that
    /// location. Restyling a table drops its rows' layout, and a row laid out on
    /// its own is placed by an estimate (a line off, after a row grew): the
    /// viewport's layout, which drawing uses, places it after the text above.
    private func layOutTable(through location: Int) -> NSTextLocation? {
        guard let layout = textLayoutManager, let storage = textStorage, location <= storage.length,
              let target = layout.location(layout.documentRange.location, offsetBy: location) else { return nil }
        let viewport = layout.textViewportLayoutController
        viewport.layoutViewport()
        if viewport.viewportRange?.contains(target) == true { return target }
        // Off screen: from the table's first row, which is close enough.
        let text = storage.mutableString
        var firstRow = text.paragraphRange(for: NSRange(location: min(location, max(storage.length - 1, 0)), length: 0)).location
        while firstRow > 0, storage.attribute(EditorTheme.tableRowKey, at: firstRow - 1, effectiveRange: nil) is TableRowLayout {
            firstRow = text.paragraphRange(for: NSRange(location: firstRow - 1, length: 0)).location
        }
        if let from = layout.location(layout.documentRange.location, offsetBy: firstRow),
           let range = NSTextRange(location: from, end: layout.location(target, offsetBy: 1) ?? target) {
            layout.ensureLayout(for: range)
        }
        return target
    }

    /// A layout fragment's origin in view coordinates.
    private func fragmentOrigin(_ fragment: NSTextLayoutFragment) -> CGPoint {
        let container = textContainerOrigin
        return CGPoint(x: container.x + fragment.layoutFragmentFrame.minX, y: container.y + fragment.layoutFragmentFrame.minY)
    }

    /// The decorated layout fragment under `point` (view coordinates), and the point in its coordinates.
    func decoratedFragment(at point: NSPoint) -> (DecoratedLayoutFragment, CGPoint)? {
        guard let layout = textLayoutManager else { return nil }
        let origin = textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        // Under the last paragraph TextKit has no fragment, but its image or a
        // table's "+" button may be drawn there (see StyleApplier.updateTrailingSpace).
        var found = layout.textLayoutFragment(for: inContainer)
        if found == nil {
            layout.enumerateTextLayoutFragments(from: layout.documentRange.endLocation, options: [.reverse]) { last in
                if inContainer.y >= last.layoutFragmentFrame.maxY { found = last }
                return false
            }
        }
        guard let fragment = found as? DecoratedLayoutFragment else { return nil }
        let frame = fragment.layoutFragmentFrame
        return (fragment, CGPoint(x: inContainer.x - frame.minX, y: inContainer.y - frame.minY))
    }

    /// Right-clicking in a table adds row and column items above the usual ones.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let cell = tableCellHit(at: convert(event.locationInWindow, from: nil)) else { return super.menu(for: event) }
        // A copy: NSTextView hands out one shared menu, which must not keep our items.
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        addTableItems(to: menu, location: cell.location)
        return menu
    }

    /// Puts the table's row and column items at the top of `menu`, acting on the
    /// cell at `location` (also used by the cell editor's menu).
    func addTableItems(to menu: NSMenu, location: Int) {
        let items: [(String, TableOperation)?] = [
            ("Add Row Above", .addRowAbove), ("Add Row Below", .addRowBelow), nil,
            ("Add Column Left", .addColumnLeft), ("Add Column Right", .addColumnRight), nil,
            ("Delete Row", .deleteRow), ("Delete Column", .deleteColumn), nil,
            ("Align Column Left", .align(.left)), ("Align Column Center", .align(.center)),
            ("Align Column Right", .align(.right)), nil,
        ]
        for (index, entry) in items.enumerated() {
            guard let (title, operation) = entry else {
                menu.insertItem(.separator(), at: index)
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(runTableMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TableMenuAction(operation: operation, location: location)
            menu.insertItem(item, at: index)
        }
    }

    @objc private func runTableMenuItem(_ item: NSMenuItem) {
        guard let action = item.representedObject as? TableMenuAction else { return }
        onTableOperation(action.operation, action.location)
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
        guard let layout = textLayoutManager, let (fragment, _) = decoratedFragment(at: point) else { return nil }
        let origin = textContainerOrigin
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
        setAccessibilityLabel("Note")
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: Self.minimumHorizontalInset, height: Self.verticalInset)
        textContainer?.lineFragmentPadding = Self.lineFragmentPadding

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

/// A table context menu item's operation and the location it was opened at.
private final class TableMenuAction: NSObject {
    let operation: TableOperation
    let location: Int
    init(operation: TableOperation, location: Int) {
        self.operation = operation
        self.location = location
    }
}
