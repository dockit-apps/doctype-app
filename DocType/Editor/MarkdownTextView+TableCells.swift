// The cursor, selection and clicks in table cells with line breaks (`<br>`).
// Their text is hidden and their lines are drawn by BlockDecorations (see
// EditorTheme+Tables), so TextKit's own cursor would sit on the hidden text.
// There, the editor hides the system cursor and draws its own cursor and
// selection on the drawn lines (a small overlay view, sized to what it shows),
// and maps clicks and drags on the lines to the text. Typing, undo and saving
// still go through the text as everywhere; the arrow keys move along the lines
// (TableEditing). Not covered: Shift-arrow selection steps over the hidden
// `<br>` one character at a time.

import AppKit

extension MarkdownTextView {
    /// A cell drawn as lines: its range in the text, its lines, and where its
    /// text's top left is (view coordinates).
    struct DrawnCell {
        let range: NSRange
        let lines: TableCellLines
        let origin: CGPoint
        /// The cell's area, padding included, for clicks.
        let frame: CGRect

        func location(at point: CGPoint) -> Int {
            range.location + lines.offset(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        }
    }

    /// The drawn cell the cursor at `location` is in (also at its very end).
    func drawnCell(containing location: Int) -> DrawnCell? {
        guard let storage = textStorage else { return nil }
        for candidate in [location, location - 1] where candidate >= 0 && candidate < storage.length {
            var range = NSRange()
            guard storage.attribute(EditorTheme.tableCellLinesKey, at: candidate, effectiveRange: &range) is TableCellLines,
                  let layout = textLayoutManager,
                  let start = layout.location(layout.documentRange.location, offsetBy: range.location) else { continue }
            layout.ensureLayout(for: NSTextRange(location: start))
            guard let fragment = layout.textLayoutFragment(for: start) as? DecoratedLayoutFragment else { return nil }
            return drawnCells(in: fragment).first { $0.range == range }
        }
        return nil
    }

    /// The drawn cell under `point`, padding included.
    func drawnCell(at point: NSPoint) -> DrawnCell? {
        guard let (fragment, _) = decoratedFragment(at: point) else { return nil }
        return drawnCells(in: fragment).first { $0.frame.contains(point) }
    }

    private func drawnCells(in fragment: DecoratedLayoutFragment) -> [DrawnCell] {
        guard let storage = textStorage, let layout = textLayoutManager else { return [] }
        let paragraphStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let container = textContainerOrigin
        return fragment.drawnTableCells.compactMap { start, lines, origin in
            var range = NSRange()
            guard paragraphStart + start < storage.length,
                  storage.attribute(EditorTheme.tableCellLinesKey, at: paragraphStart + start, effectiveRange: &range) != nil
            else { return nil }
            let inView = CGPoint(x: container.x + frame.minX + origin.x, y: container.y + frame.minY + origin.y)
            let padding = EditorTheme.tableCellPadding
            let area = CGRect(x: inView.x - padding, y: container.y + frame.minY,
                              width: lines.columnWidth + 2 * padding, height: frame.height)
            return DrawnCell(range: range, lines: lines, origin: inView, frame: area)
        }
    }

    // MARK: - Clicks

    /// A click on a drawn cell's lines: the cursor goes where it would in text.
    /// Returns false when `point` isn't on one.
    func clickDrawnCell(at point: NSPoint, with event: NSEvent) -> Bool {
        guard let cell = drawnCell(at: point) else { return false }
        window?.makeFirstResponder(self)
        let location = cell.location(at: point)
        var selection = NSRange(location: location, length: 0)
        if event.clickCount == 2 {
            selection = selectionRange(forProposedRange: selection, granularity: .selectByWord)
        } else if event.clickCount >= 3 {
            let line = cell.lines.lineRanges[cell.lines.line(of: location - cell.range.location)]
            selection = NSRange(location: cell.range.location + line.location, length: line.length)
        } else if event.modifierFlags.contains(.shift) {
            selection = NSUnionRange(selectedRange(), selection)
        }
        setSelectedRange(selection)
        cellDrag = (anchor: selection.location, cell: cell)
        return true
    }

    /// Dragging from a click in a drawn cell selects within it.
    func dragInDrawnCell(to point: NSPoint) -> Bool {
        guard let drag = cellDrag else { return false }
        let location = drag.cell.location(at: point)
        setSelectedRange(NSRange(location: min(drag.anchor, location), length: abs(location - drag.anchor)))
        return true
    }

    // MARK: - Cursor and selection

    /// Shows the cursor or selection on drawn cell lines, and hides the system
    /// cursor while it's in such a cell. Call after the selection, the text or
    /// the layout changed.
    func updateDrawnCellCursor() {
        let selection = selectedRange()
        let isFocused = window?.isKeyWindow == true && window?.firstResponder === self
        guard let cell = drawnCell(containing: selection.location),
              selection.upperBound <= cell.range.upperBound else {
            cellOverlay.isHidden = true
            if hidesSystemCursor {
                hidesSystemCursor = false
                insertionPointColor = cellOverlay.caretColor
            }
            return
        }
        if !hidesSystemCursor {
            // The system cursor would show on the hidden text. (Its selection
            // there is covered by BlockDecorations.)
            hidesSystemCursor = true
            cellOverlay.caretColor = insertionPointColor
            insertionPointColor = .clear
        }
        if cellOverlay.superview !== self { addSubview(cellOverlay) }
        let start = selection.location - cell.range.location
        let height = EditorTheme.tableLineAdvance - EditorTheme.tableLineSpacing
        if selection.length == 0 {
            let point = cell.lines.caretPoint(at: start)
            cellOverlay.show(caret: CGRect(x: cell.origin.x + point.x, y: cell.origin.y + point.y, width: 2, height: height),
                             visible: isFocused)
        } else {
            // One rectangle per line the selection touches.
            let end = selection.upperBound - cell.range.location
            var rects: [CGRect] = []
            for (index, line) in cell.lines.lineRanges.enumerated() {
                let from = max(start, line.location), to = min(end, line.upperBound)
                guard from <= to, from <= line.upperBound, to >= line.location else { continue }
                let a = cell.lines.caretPoint(at: from), b = cell.lines.caretPoint(at: to)
                let y = cell.origin.y + CGFloat(index) * EditorTheme.tableLineAdvance
                rects.append(CGRect(x: cell.origin.x + a.x, y: y, width: max(b.x - a.x, 4), height: height))
            }
            cellOverlay.show(selection: rects, focused: isFocused)
        }
    }
}

/// Draws the cursor (blinking) or the selection on a drawn table cell's lines.
/// Never takes clicks.
final class TableCellOverlayView: NSView {
    var caretColor: NSColor = .controlAccentColor
    private var selectionRects: [CGRect] = []
    private var selectionFocused = true

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(caret: CGRect, visible: Bool) {
        selectionRects = []
        frame = caret
        isHidden = !visible
        layer?.backgroundColor = caretColor.cgColor
        needsDisplay = true
        // Blinks like the system cursor, restarted so it shows right after a move.
        layer?.removeAnimation(forKey: "blink")
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.duration = 1.06
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + 0.5
        layer?.add(blink, forKey: "blink")
    }

    func show(selection rects: [CGRect], focused: Bool) {
        layer?.removeAnimation(forKey: "blink")
        layer?.backgroundColor = nil
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else {
            isHidden = true
            return
        }
        frame = union
        selectionRects = rects.map { $0.offsetBy(dx: -union.minX, dy: -union.minY) }
        selectionFocused = focused
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !selectionRects.isEmpty else { return }
        // Drawn over the text, so see-through.
        let color = selectionFocused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
        color.withAlphaComponent(0.45).setFill()
        for rect in selectionRects { rect.fill() }
    }
}
