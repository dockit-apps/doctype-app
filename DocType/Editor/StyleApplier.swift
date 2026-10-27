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

    /// Replaces the whole text with an already-styled document (opening a note).
    /// `selection` is where the cursor will be, which decides the visible markers.
    func replaceDocument(in storage: NSTextStorage, text: String, blockMap: BlockMap, spans: [StyleSpan],
                         selection: NSRange) {
        let attributed = NSMutableAttributedString(string: text)
        EditorTheme.apply(spans, to: attributed, resetting: NSRange(location: 0, length: attributed.length),
                          selection: selection)
        styledSelection = selection
        isReplacingDocument = true
        storage.setAttributedString(attributed)
        isReplacingDocument = false
        self.blockMap = blockMap
        pendingRange = nil
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
        guard let textView, pendingRange == nil, !textView.hasMarkedText() else { return }
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
            return NSUnionRange(first.range, last.range)
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
    }

    private func apply(_ range: NSRange, in storage: NSTextStorage, selection: NSRange) {
        let spans = MarkdownStyler.spans(in: storage.mutableString, blocks: blockMap.blocks(in: range))
        EditorTheme.apply(spans, to: storage, resetting: range, selection: selection)
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
