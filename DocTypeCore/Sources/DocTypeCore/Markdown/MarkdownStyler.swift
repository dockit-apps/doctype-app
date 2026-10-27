// Decides how each block of a note is styled, as a list of StyleSpans.
//
// Code blocks are styled straight from the BlockMap (no parsing needed). Text
// blocks are parsed one at a time with swift-markdown, which is what keeps
// restyling after a keystroke cheap: only the edited block is parsed again.
//
// Within a block, container styles (heading, quote, code) come first and syntax
// markers after, so a marker dims its color but keeps the heading's size.
//
// Constructs only format once their syntax is followed by a space, so nothing
// jumps while you type: `>` stays plain until `> `, and `---` (or a setext
// underline) stays plain on the cursor's line until a space follows it or the
// cursor leaves the line (see StyleSpan.unconfirmedRange).

import Foundation
import Markdown
import os

public enum MarkdownStyler {
    /// Spans for the given blocks of `text`.
    public static func spans(in text: NSString, blocks: some Sequence<Block>) -> [StyleSpan] {
        blocks.flatMap { spans(for: $0, in: text) }
    }

    /// Styles a whole document off the main thread, for opening a note.
    @concurrent
    public static func styleDocument(_ text: String) async -> (blockMap: BlockMap, spans: [StyleSpan]) {
        let string = text as NSString
        let blockMap = BlockMap(text: string)
        return (blockMap, spans(in: string, blocks: blockMap.blocks))
    }

    static func spans(for block: Block, in text: NSString) -> [StyleSpan] {
        // A block from a map that doesn't match this text would make NSString throw;
        // an Objective-C exception inside a Swift task corrupts the concurrency
        // runtime, so refuse it instead (the caller's map is out of date).
        guard block.range.location >= 0, NSMaxRange(block.range) <= text.length else {
            DocTypeCore.logger.fault("Styling a block \(NSStringFromRange(block.range)) outside the text (length \(text.length))")
            return []
        }
        return switch block.kind {
        case .code: codeBlockSpans(block, in: text)
        case .text: textBlockSpans(block, in: text)
        }
    }

    // MARK: - Code blocks

    /// Monospace for the fence lines and everything between, code tokens colored
    /// by language, fences dimmed.
    /// Trailing blank lines after the closing fence stay unstyled.
    private static func codeBlockSpans(_ block: Block, in text: NSString) -> [StyleSpan] {
        let opening = Line(text, at: block.range.location)
        guard let fence = opening.opensFence() else { return [] }
        var spans: [StyleSpan] = []
        var codeEnd = opening.end
        var closing: Line?
        var position = opening.end
        while position < block.range.upperBound {
            let line = Line(text, at: position)
            if !line.isBlank { codeEnd = line.start + line.content.length }
            if line.closes(fence) {
                closing = line
                break
            }
            position = line.end
        }
        if closing == nil { codeEnd = max(codeEnd, block.range.upperBound) }
        spans.append(StyleSpan(NSRange(location: block.range.location, length: codeEnd - block.range.location), .codeBlock))
        let codeStart = opening.end
        let codeStop = max(codeStart, closing?.start ?? codeEnd)
        spans += CodeHighlighter.spans(in: text, range: NSRange(location: codeStart, length: codeStop - codeStart),
                                       language: fence.info)
        // Fences show while the cursor is anywhere in the block. They include their
        // line break, so a hidden fence line takes no height.
        let blockRange = NSRange(location: block.range.location, length: codeEnd - block.range.location)
        spans.append(StyleSpan(NSRange(location: opening.start, length: opening.end - opening.start), .syntaxMarker,
                               revealRange: blockRange))
        if let closing {
            spans.append(StyleSpan(NSRange(location: closing.start, length: closing.end - closing.start), .syntaxMarker,
                                   revealRange: blockRange))
        }
        return spans
    }

    // MARK: - Text blocks

    private static func textBlockSpans(_ block: Block, in text: NSString) -> [StyleSpan] {
        let source = text.substring(with: block.range)
        var collector = SpanCollector(source: source as NSString, mapping: SourceMapping(source), base: block.range.location)
        collector.visit(Document(parsing: source))
        // Containers first (heading size), then inline styles, then markers on top.
        return collector.containerSpans + collector.inlineSpans + collector.markerSpans
    }
}
