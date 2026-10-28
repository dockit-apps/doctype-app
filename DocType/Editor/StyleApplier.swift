// Keeps the editor's markdown styling up to date as you type, in two steps:
//
// 1. During an edit (`willProcessEditing`) only the BlockMap is updated and the
//    dirty range remembered. Attributes are NOT changed here: that would enlarge
//    the range TextKit 2 treats as replaced, and it would move the cursor to the
//    end of that range (typing in the middle of a note jumped lines).
// 2. After the edit (`applyPendingStyles`, called from textDidChange) the dirty
//    blocks are restyled as a separate, attribute-only edit, which leaves the
//    selection alone.
//
// DocTypeCore decides the spans; EditorTheme turns them into fonts and colors.

import AppKit
import DocTypeCore
import os

final class StyleApplier: NSObject, NSTextStorageDelegate {
    weak var textView: NSTextView?
    private(set) var blockMap = BlockMap()
    private var isReplacingDocument = false
    /// Range edited but not yet restyled (applied after the edit, or after composing).
    private var pendingRange: NSRange?
    /// The selection the current styles were applied for (markers on its lines are shown).
    private var styledSelection = NSRange(location: 0, length: 0)
    /// How to find the open note's images; nil shows image syntax as text.
    var imageContext: ImageContext?
    /// Called with images found while styling `range` that need measuring first;
    /// restyle the range once they are.
    var onUnmeasuredImages: (_ urls: [URL], _ range: NSRange) -> Void = { _, _ in }

    /// The image context with the editor's current width.
    private var currentImageContext: ImageContext? {
        guard var context = imageContext else { return nil }
        if let container = textView?.textContainer, container.size.width > 100 {
            context.maxWidth = container.size.width - 2 * container.lineFragmentPadding
        }
        return context
    }

    /// Replaces the whole text with an already-styled document (opening a note).
    /// `selection` is where the cursor will be, which decides the visible markers.
    func replaceDocument(in storage: NSTextStorage, text: String, blockMap: BlockMap, spans: [StyleSpan],
                         selection: NSRange) {
        let attributed = NSMutableAttributedString(string: text)
        let whole = NSRange(location: 0, length: attributed.length)
        let unmeasured = EditorTheme.apply(spans, to: attributed, resetting: whole, selection: selection,
                                           images: currentImageContext)
        // The new map goes in before the new text, and nothing restyles during the
        // swap: TextKit adjusts the selection (and tells the delegate) in the middle
        // of it, while the text is already styled for `selection`.
        self.blockMap = blockMap
        styledSelection = selection
        pendingRange = nil
        isReplacingDocument = true
        defer { isReplacingDocument = false }
        storage.setAttributedString(attributed)
        updateTrailingSpace(in: storage)
        if !unmeasured.isEmpty { onUnmeasuredImages(unmeasured, whole) }
    }

    /// Restyles the blocks overlapping `ranges` (e.g. after their images loaded).
    func restyle(_ ranges: [NSRange], in storage: NSTextStorage) {
        guard pendingRange == nil, textView?.hasMarkedText() != true else { return }
        restyleBlocks(touching: ranges, in: storage)
    }

    /// Shows the image whose syntax starts at `location` at `width` while its
    /// resize handle is dragged; nil goes back to the width in the text.
    func previewImageWidth(_ width: CGFloat?, at location: Int, in storage: NSTextStorage) {
        imageContext?.widthOverride = width.map { (location, $0) }
        restyle([NSRange(location: location, length: 0)], in: storage)
    }

    func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isReplacingDocument else { return }

        let dirty = blockMap.update(text: textStorage.mutableString, editedRange: editedRange, changeInLength: delta)
        // Several edits can happen before styles are applied (e.g. while an input
        // method is composing), so earlier ranges move with later edits.
        let previous = pendingRange.map { Self.shift($0, by: editedRange, delta: delta) }
        pendingRange = previous.map { NSUnionRange($0, dirty) } ?? dirty
        styledSelection = Self.shift(styledSelection, by: editedRange, delta: delta)
    }

    /// Restyles everything edited since the last call, as an attribute-only edit.
    /// Call after each text change. Waits while an input method is composing,
    /// because changing attributes mid-composition can disturb it.
    func applyPendingStyles(in storage: NSTextStorage) {
        guard let pending = pendingRange, textView?.hasMarkedText() != true else { return }
        pendingRange = nil
        let state = DocTypeCore.signposter.beginInterval("Restyle")
        defer { DocTypeCore.signposter.endInterval("Restyle", state) }

        // Also the line the cursor was on: an edit (e.g. Undo) can move the cursor
        // far away, and that line's markers must hide again.
        restyleBlocks(touching: [pending, styledSelection], in: storage)
    }

    /// Shows the markers on the line the cursor moved to and hides the ones it left.
    /// Only the blocks around the old and new cursor are restyled.
    func selectionDidChange(in storage: NSTextStorage) {
        guard let textView, pendingRange == nil, !isReplacingDocument, !textView.hasMarkedText() else { return }
        let selection = textView.selectedRange()
        let previous = styledSelection
        let text = storage.mutableString
        let clampedPrevious = Self.clamp(previous, toLength: text.length)
        guard text.paragraphRange(for: clampedPrevious) != text.paragraphRange(for: selection) else {
            styledSelection = selection
            return
        }
        // Moving within one code block changes nothing (its fences show for the
        // whole block), and re-highlighting a big block per arrow key would be wasteful.
        let previousBlocks = blockMap.blocks(in: clampedPrevious), currentBlocks = blockMap.blocks(in: selection)
        if previousBlocks.count == 1, previousBlocks == currentBlocks, case .code = currentBlocks.first?.kind {
            styledSelection = selection
            return
        }
        restyleBlocks(touching: [clampedPrevious, selection], in: storage)
    }

    /// Restyles the blocks overlapping `ranges` as one attribute-only edit.
    private func restyleBlocks(touching ranges: [NSRange], in storage: NSTextStorage) {
        let blockRanges = ranges.compactMap { range -> NSRange? in
            let blocks = blockMap.blocks(in: Self.clamp(range, toLength: storage.length))
            guard let first = blocks.first, let last = blocks.last else { return nil }
            let union = NSUnionRange(first.range, last.range)
            // A map that doesn't fit the text is a bug; never pass it to NSString.
            guard NSMaxRange(union) <= storage.length else {
                DocTypeCore.logger.fault("Block map out of date: \(NSStringFromRange(union)) in \(storage.length) characters")
                return nil
            }
            return union
        }
        guard !blockRanges.isEmpty else { return }
        let selection = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        let restyle = {
            storage.beginEditing()
            for range in blockRanges { self.apply(range, in: storage, selection: selection) }
            storage.endEditing()
        }
        if let contentStorage = textView?.textContentStorage {
            contentStorage.performEditingTransaction(restyle)
        } else {
            restyle()
        }
        styledSelection = selection
        updateTrailingSpace(in: storage)
    }

    /// TextKit leaves out the spacing under a note's last paragraph, where an
    /// image or a table's "+" button there is drawn; the editor adds it below the
    /// text instead. With a line break at the end, the empty last line keeps it.
    private func updateTrailingSpace(in storage: NSTextStorage) {
        guard let textView = textView as? MarkdownTextView else { return }
        let string = storage.mutableString
        var space: CGFloat = 0
        if string.length > 0, ![10, 13].contains(string.character(at: string.length - 1)) {  // "\n", "\r"
            let style = storage.attribute(.paragraphStyle, at: string.length - 1, effectiveRange: nil) as? NSParagraphStyle
            space = style?.paragraphSpacing ?? 0
        }
        textView.trailingSpace = space
    }

    private func apply(_ range: NSRange, in storage: NSTextStorage, selection: NSRange) {
        let spans = MarkdownStyler.spans(in: storage.mutableString, blocks: blockMap.blocks(in: range))
        let unmeasured = EditorTheme.apply(spans, to: storage, resetting: range, selection: selection,
                                           images: currentImageContext)
        if !unmeasured.isEmpty { onUnmeasuredImages(unmeasured, range) }
    }

    /// Keeps a range inside the text. Unlike NSIntersectionRange, an empty range at
    /// the very end (a cursor after the last character) stays where it is instead
    /// of becoming {0, 0}.
    static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    /// Moves a range recorded before an edit into post-edit coordinates.
    private static func shift(_ range: NSRange, by edit: NSRange, delta: Int) -> NSRange {
        let oldEditEnd = edit.upperBound - delta
        func move(_ position: Int) -> Int {
            position >= oldEditEnd ? position + delta : min(position, edit.upperBound)
        }
        let start = move(range.location), end = move(range.upperBound)
        return NSRange(location: start, length: max(end - start, 0))
    }
}
