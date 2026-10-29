// Find's highlights in tables. NSTextView is its find bar's client
// (NSTextFinderClient): the find bar asks it where a match is drawn
// (rectsForCharacterRange:) and has it draw the match's characters over the
// yellow highlight (drawCharactersInRange:forContentView:). In a table the
// markdown is hidden and drawn elsewhere, as cells, so for a match there the
// answers come from the cells' layout instead.
//
// NSTextView's headers don't declare these methods, so the overrides are
// bound by selector, and NSTextView's own are called through their
// implementation. Alternative considered: a find bar of our own (NSTextFinder
// with a custom client) for the whole note, which would mean redoing
// everything NSTextView's find already does for the rest of the text.

import AppKit
import DocTypeCore

extension MarkdownTextView {
    @objc(rectsForCharacterRange:)
    func findRects(forCharacterRange range: NSRange) -> [NSValue]? {
        if let matches = tableMatches(in: range, layingOut: true) {
            return matches.flatMap(\.rects).map { NSValue(rect: $0) }
        }
        return Self.textViewRects(self, range)
    }

    @objc(drawCharactersInRange:forContentView:)
    func findDrawCharacters(in range: NSRange, forContentView view: NSView) {
        // While drawing, nothing is laid out: a match not laid out isn't on screen.
        guard let matches = tableMatches(in: range, layingOut: false) else {
            return Self.textViewDrawCharacters(self, range, view)
        }
        for match in matches where !match.rects.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath()
            match.rects.forEach { clip.appendRect($0) }
            clip.addClip()
            match.text.draw(with: match.frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Where the part of `range` in a table row is drawn (view coordinates):
    /// for each cell it's in, the cell's text and frame and the matched
    /// characters' rectangles. Nil when `range` doesn't start in a table row.
    func tableMatches(in range: NSRange, layingOut: Bool)
        -> [(text: NSAttributedString, frame: CGRect, rects: [CGRect])]? {
        guard let storage = textStorage, let layout = textLayoutManager, range.length > 0,
              NSMaxRange(range) <= storage.length,
              storage.attribute(EditorTheme.tableRowKey, at: range.location, effectiveRange: nil) is TableRowLayout
        else { return nil }
        guard let fragment = tableRowFragment(at: range.location, layingOut: layingOut), let row = fragment.tableRow
        else { return [] }
        let rowStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        let origin = fragmentOrigin(fragment)
        let text = storage.mutableString
        return row.cells.compactMap { cell in
            let content = NSRange(location: rowStart + cell.content.location, length: cell.content.length)
            let matched = NSIntersectionRange(range, content)
            guard !cell.isEditing, matched.length > 0 else { return nil }
            let shown = TableCellText(markdown: text.substring(with: content)).editorRange(
                forMarkdownRange: NSRange(location: matched.location - content.location, length: matched.length))
            let frame = cell.frame.offsetBy(dx: origin.x, dy: origin.y)
            let rects = EditorTheme.cellTextRects(cell.text, width: cell.frame.width, range: shown)
                .map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
            return (cell.text, frame, rects)
        }
    }

    /// The laid-out fragment of the table row at `location`; laid out first
    /// if needed and `layingOut`.
    private func tableRowFragment(at location: Int, layingOut: Bool) -> DecoratedLayoutFragment? {
        guard let layout = textLayoutManager,
              let target = layout.location(layout.documentRange.location, offsetBy: location) else { return nil }
        if let fragment = layout.textLayoutFragment(for: target) as? DecoratedLayoutFragment,
           fragment.state == .layoutAvailable, fragment.tableRow != nil {
            return fragment
        }
        guard layingOut, let start = layOutTable(through: location) else { return nil }
        return layout.textLayoutFragment(for: start) as? DecoratedLayoutFragment
    }

    // MARK: - NSTextView's own

    private static let textViewRects: (NSTextView, NSRange) -> [NSValue]? = {
        let selector = #selector(findRects(forCharacterRange:))
        typealias Method = @convention(c) (NSTextView, Selector, NSRange) -> NSArray?
        let method = unsafeBitCast(class_getMethodImplementation(NSTextView.self, selector)!, to: Method.self)
        return { view, range in method(view, selector, range) as? [NSValue] }
    }()

    private static let textViewDrawCharacters: (NSTextView, NSRange, NSView) -> Void = {
        let selector = #selector(findDrawCharacters(in:forContentView:))
        typealias Method = @convention(c) (NSTextView, Selector, NSRange, NSView) -> Void
        let method = unsafeBitCast(class_getMethodImplementation(NSTextView.self, selector)!, to: Method.self)
        return { view, range, contentView in method(view, selector, range, contentView) }
    }()
}
