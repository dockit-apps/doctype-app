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
    /// Range skipped while an input method was composing (marked text).
    private var pendingRange: NSRange?

    /// Replaces the whole text with an already-styled document (opening a note).
    func replaceDocument(in storage: NSTextStorage, text: String, blockMap: BlockMap, spans: [StyleSpan]) {
        let attributed = NSMutableAttributedString(string: text)
        EditorTheme.apply(spans, to: attributed, resetting: NSRange(location: 0, length: attributed.length))
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
    }

    /// Restyles everything edited since the last call, as an attribute-only edit.
    /// Call after each text change. Waits while an input method is composing,
    /// because changing attributes mid-composition can disturb it.
    func applyPendingStyles(in storage: NSTextStorage) {
        guard let pending = pendingRange, textView?.hasMarkedText() != true else { return }
        pendingRange = nil
        let state = DocTypeCore.signposter.beginInterval("Restyle")
        defer { DocTypeCore.signposter.endInterval("Restyle", state) }

        let clamped = NSIntersectionRange(pending, NSRange(location: 0, length: storage.length))
        let blocks = blockMap.blocks(in: clamped)
        guard let first = blocks.first, let last = blocks.last else { return }
        let apply = {
            storage.beginEditing()
            self.apply(NSUnionRange(first.range, last.range), in: storage)
            storage.endEditing()
        }
        if let contentStorage = textView?.textContentStorage {
            contentStorage.performEditingTransaction(apply)
        } else {
            apply()
        }
    }

    private func apply(_ range: NSRange, in storage: NSTextStorage) {
        let spans = MarkdownStyler.spans(in: storage.mutableString, blocks: blockMap.blocks(in: range))
        EditorTheme.apply(spans, to: storage, resetting: range)
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
