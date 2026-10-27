// Splits a note's body into blocks, the unit the editor restyles after an edit.
//
// - A fenced code block (``` or ~~~) runs from its opening fence to the matching
//   closing fence (or to the end of the note), blank lines included.
// - Everything else is a text block. A blank line ends a text block, unless the
//   next non-blank line is indented, which keeps list items with several
//   paragraphs together.
// - Blank lines after a block belong to that block, so the blocks cover the
//   whole text with no gaps.
//
// This is deliberately simpler than full CommonMark (e.g. HTML blocks aren't
// special). It only decides what to re-parse; swift-markdown parses each block,
// and the preview renders the whole document exactly.
//
// All positions are UTF-16 offsets (NSString/NSRange), like NSTextStorage.

import Foundation

public struct Block: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text
        /// A fenced code block; `language` is the info string after the fence ("swift"), or "".
        case code(language: String)
    }

    public var range: NSRange
    public var kind: Kind
}

public struct BlockMap: Equatable, Sendable {
    public private(set) var blocks: [Block] = []

    public init() {}

    public init(text: NSString) {
        blocks = Self.scan(text, from: 0) { _ in false }.blocks
    }

    /// The blocks overlapping `range` (all of them for a range at a block boundary).
    public func blocks(in range: NSRange) -> ArraySlice<Block> {
        guard !blocks.isEmpty else { return [] }
        let first = index(containing: range.location)
        var last = first
        while last + 1 < blocks.count, blocks[last + 1].range.location < range.upperBound { last += 1 }
        return blocks[first...last]
    }

    /// Updates the map after an edit and returns the range that must be restyled:
    /// normally the edited block and the one before it, but up to the end of the
    /// text if the edit opened or closed a code fence.
    /// - Parameters:
    ///   - text: the text after the edit.
    ///   - editedRange: the changed range, in post-edit coordinates.
    ///   - delta: the change in length (inserted minus deleted characters).
    public mutating func update(text: NSString, editedRange: NSRange, changeInLength delta: Int) -> NSRange {
        guard !blocks.isEmpty else {
            self = BlockMap(text: text)
            return NSRange(location: 0, length: text.length)
        }
        // Start one block early: an edit at the top of a block can merge it into the previous one.
        let first = max(index(containing: editedRange.location) - 1, 0)
        let rescanStart = blocks[first].range.location
        let oldStarts = blocks[(first + 1)...].map(\.range.location)

        let result = Self.scan(text, from: rescanStart) { position in
            // Safe to stop where an unchanged old block starts again, past the edit.
            position >= editedRange.upperBound && oldStarts.binarySearch(position - delta) != nil
        }

        var tail: [Block] = []
        if let stop = result.stoppedAt, let offset = oldStarts.binarySearch(stop - delta) {
            tail = blocks[(first + 1 + offset)...].map { block in
                Block(range: NSRange(location: block.range.location + delta, length: block.range.length), kind: block.kind)
            }
        }
        blocks = Array(blocks[..<first]) + result.blocks + tail
        return NSRange(location: rescanStart, length: (result.stoppedAt ?? text.length) - rescanStart)
    }

    /// Index of the block containing `location` (the last block for the end of the text).
    private func index(containing location: Int) -> Int {
        var low = 0, high = blocks.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if blocks[middle].range.location <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }

    // MARK: - Scanning

    /// Scans lines from `start` (which must be a block start) and builds blocks.
    /// Before starting each new block after the first, asks `shouldStop`; if it
    /// says yes, scanning ends there and `stoppedAt` is that position.
    static func scan(
        _ text: NSString, from start: Int, shouldStop: (Int) -> Bool
    ) -> (blocks: [Block], stoppedAt: Int?) {
        var blocks: [Block] = []
        var current: (start: Int, kind: Block.Kind)?
        var openFence: Fence?
        var fenceJustClosed = false
        var previousLineBlank = false
        var position = start

        while position < text.length {
            let line = Line(text, at: position)
            var newBlockKind: Block.Kind?

            if let fence = openFence {
                if line.closes(fence) {
                    openFence = nil
                    fenceJustClosed = true
                }
            } else if let fence = line.opensFence() {
                newBlockKind = .code(language: fence.info)
                openFence = fence
                fenceJustClosed = false
            } else if line.isBlank {
                if current == nil { newBlockKind = .text }  // blank lines at the very top
            } else {
                if current == nil || fenceJustClosed || (previousLineBlank && !line.isIndented) {
                    newBlockKind = .text
                }
                fenceJustClosed = false
            }

            if let kind = newBlockKind {
                if let open = current {
                    blocks.append(Block(range: NSRange(location: open.start, length: line.start - open.start), kind: open.kind))
                    if shouldStop(line.start) { return (blocks, line.start) }
                }
                current = (line.start, kind)
            }
            previousLineBlank = openFence == nil && line.isBlank
            position = line.end
        }
        if let open = current {
            blocks.append(Block(range: NSRange(location: open.start, length: text.length - open.start), kind: open.kind))
        }
        return (blocks, nil)
    }
}

/// An open code fence: its character (` or ~), length, and info string.
struct Fence: Equatable {
    let character: unichar
    let length: Int
    let info: String
}

/// One line of the text, with the few facts the scanner needs.
struct Line {
    let start: Int
    /// After the line break.
    let end: Int
    /// The line without its line break.
    let content: NSString

    init(_ text: NSString, at position: Int) {
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
        self.start = start
        self.end = end
        content = text.substring(with: NSRange(location: start, length: contentsEnd - start)) as NSString
    }

    private static let space = unichar(UInt8(ascii: " "))
    private static let tab = unichar(UInt8(ascii: "\t"))
    private static let backtick = unichar(UInt8(ascii: "`"))
    private static let tilde = unichar(UInt8(ascii: "~"))

    /// Number of leading spaces and tabs.
    var indentation: Int {
        var count = 0
        while count < content.length, [Self.space, Self.tab].contains(content.character(at: count)) { count += 1 }
        return count
    }

    var isBlank: Bool { indentation == content.length }
    var isIndented: Bool { indentation > 0 && !isBlank }

    /// Length of the run of `character` starting at `index`.
    private func run(of character: unichar, from index: Int) -> Int {
        var end = index
        while end < content.length, content.character(at: end) == character { end += 1 }
        return end - index
    }

    /// ``` or ~~~ (three or more) after any indentation. A backtick fence's info
    /// string can't contain backticks, so ```inline``` code isn't a fence.
    func opensFence() -> Fence? {
        let first = indentation
        guard first < content.length else { return nil }
        let character = content.character(at: first)
        guard character == Self.backtick || character == Self.tilde else { return nil }
        let length = run(of: character, from: first)
        guard length >= 3 else { return nil }
        let info = content.substring(from: first + length).trimmingCharacters(in: .whitespaces)
        if character == Self.backtick, info.contains("`") { return nil }
        return Fence(character: character, length: length, info: info)
    }

    /// The same fence character, at least as many, and nothing else on the line.
    func closes(_ fence: Fence) -> Bool {
        let first = indentation
        guard first < content.length, content.character(at: first) == fence.character else { return false }
        let length = run(of: fence.character, from: first)
        guard length >= fence.length else { return false }
        return content.substring(from: first + length).trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension Array where Element == Int {
    /// Index of `value` in this sorted array, or nil.
    func binarySearch(_ value: Int) -> Int? {
        var low = 0, high = count - 1
        while low <= high {
            let middle = (low + high) / 2
            if self[middle] == value { return middle }
            if self[middle] < value { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }
}
