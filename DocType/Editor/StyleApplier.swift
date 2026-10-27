// Keeps the editor's markdown styling up to date as you type.
//
// On every edit, NSTextStorage calls `willProcessEditing`. Apple documents this
// hook as the place to adjust attributes, and it runs before attribute fixing,
// so emoji and other characters still get font fallback. Here we update the
// BlockMap and restyle only the dirty blocks (DocTypeCore decides the spans;
// EditorTheme turns them into fonts and colors).

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
        let attributed = NSMutableAttributedString(string: text, attributes: EditorTheme.baseAttributes)
        for span in spans {
            attributed.addAttributes(EditorTheme.attributes(for: span.style), range: span.range)
        }
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
        let state = DocTypeCore.signposter.beginInterval("Restyle")
        defer { DocTypeCore.signposter.endInterval("Restyle", state) }

        let dirty = blockMap.update(text: textStorage.mutableString, editedRange: editedRange, changeInLength: delta)
        if textView?.hasMarkedText() == true {
            // Changing attributes mid-composition can disturb the input method;
            // remember the range and style it when composition ends.
            let previous = pendingRange.map { Self.shift($0, by: editedRange, delta: delta) }
            pendingRange = previous.map { NSUnionRange($0, dirty) } ?? dirty
            return
        }
        apply(dirty, in: textStorage)
    }

    /// Styles text that was skipped while composing. Call after each text change.
    func restylePending(in storage: NSTextStorage) {
        guard let pending = pendingRange, textView?.hasMarkedText() != true else { return }
        pendingRange = nil
        let clamped = NSIntersectionRange(pending, NSRange(location: 0, length: storage.length))
        let blocks = blockMap.blocks(in: clamped)
        guard let first = blocks.first, let last = blocks.last else { return }
        storage.beginEditing()
        apply(NSUnionRange(first.range, last.range), in: storage)
        storage.endEditing()
    }

    private func apply(_ range: NSRange, in storage: NSTextStorage) {
        let spans = MarkdownStyler.spans(in: storage.mutableString, blocks: blockMap.blocks(in: range))
        storage.setAttributes(EditorTheme.baseAttributes, range: range)
        for span in spans {
            storage.addAttributes(EditorTheme.attributes(for: span.style), range: span.range)
        }
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
