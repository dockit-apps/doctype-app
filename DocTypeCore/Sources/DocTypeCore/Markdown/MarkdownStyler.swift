// Decides how each block of a note is styled, as a list of StyleSpans.
//
// Code blocks are styled straight from the BlockMap (no parsing needed). Text
// blocks are parsed one at a time with swift-markdown, which is what keeps
// restyling after a keystroke cheap: only the edited block is parsed again.
//
// Within a block, container styles (heading, quote, code) come first and syntax
// markers after, so a marker dims its color but keeps the heading's size.

import Foundation
import Markdown

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
        switch block.kind {
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
        return collector.containerSpans + collector.markerSpans
    }
}

/// Walks one block's markdown tree and records spans in document coordinates.
private struct SpanCollector: MarkupWalker {
    let source: NSString
    let mapping: SourceMapping
    let base: Int
    var containerSpans: [StyleSpan] = []
    var markerSpans: [StyleSpan] = []

    /// The node's range relative to the block (not yet shifted by `base`).
    private func localRange(_ markup: Markup) -> NSRange? {
        markup.range.map { mapping.range(of: $0, base: 0) }
    }

    /// Adds a marker that shows while the cursor is on its line (or in `revealIn`).
    private mutating func marker(_ local: NSRange, revealIn reveal: NSRange? = nil) {
        guard local.length > 0 else { return }
        let line = reveal ?? lineWithoutBreak(containing: local.location)
        markerSpans.append(StyleSpan(NSRange(location: base + local.location, length: local.length), .syntaxMarker,
                                     revealRange: NSRange(location: base + line.location, length: line.length)))
    }

    private func lineWithoutBreak(containing location: Int) -> NSRange {
        var start = 0, contentsEnd = 0
        source.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    private mutating func container(_ local: NSRange, _ style: Style) {
        containerSpans.append(StyleSpan(NSRange(location: base + local.location, length: local.length), style))
    }

    mutating func visitHeading(_ heading: Heading) {
        guard let range = localRange(heading) else { return }
        let firstLine = source.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = source.substring(with: firstLine) as NSString
        let hashes = lineText.range(of: "^ {0,3}#{1,6}[ \\t]*", options: .regularExpression)
        if hashes.location != NSNotFound {
            // swift-markdown's range stops before a closing " ###"; cover the whole line.
            let lineLength = (lineText.trimmingCharacters(in: .newlines) as NSString).length
            container(NSRange(location: firstLine.location, length: lineLength), .heading(level: heading.level))
            // ATX heading: "## " at the start (and an optional closing " ##").
            marker(NSRange(location: firstLine.location + hashes.location, length: hashes.length))
            let closing = lineText.range(of: "[ \\t]+#+[ \\t]*(\\r?\\n)?$", options: .regularExpression)
            if closing.location != NSNotFound, closing.location > hashes.upperBound {
                let trimmed = lineText.substring(with: closing).trimmingCharacters(in: .newlines) as NSString
                marker(NSRange(location: firstLine.location + closing.location, length: trimmed.length))
            }
        } else {
            container(range, .heading(level: heading.level))
            // Setext heading: the ==== or ---- underline is the last line of the range.
            let lastLine = source.lineRange(for: NSRange(location: max(range.upperBound - 1, range.location), length: 0))
            let underline = (source.substring(with: lastLine) as NSString).trimmingCharacters(in: .newlines) as NSString
            marker(NSRange(location: lastLine.location, length: underline.length),
                   revealIn: NSRange(location: range.location, length: lastLine.location + underline.length - range.location))
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        guard let range = localRange(blockQuote) else { return }
        container(range, .blockquote)
        // Dim the ">" (and ">>" for nested quotes) at the start of each line.
        var lineRanges: [NSRange] = []
        source.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            lineRanges.append(lineRange)
        }
        for lineRange in lineRanges {
            let line = source.substring(with: lineRange) as NSString
            let quote = line.range(of: "^ {0,3}(> ?)+", options: .regularExpression)
            if quote.location != NSNotFound {
                marker(NSRange(location: lineRange.location + quote.location, length: quote.length))
            }
        }
        descendInto(blockQuote)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        guard let range = localRange(thematicBreak) else { return }
        let line = NSRange(location: range.location, length: trimmedLength(range))
        container(line, .horizontalRule)
        marker(line)
    }

    /// Code that swift-markdown finds inside a text block: indented code, or a
    /// fence inside a quote. Fenced code at the top level is a block of its own.
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let range = localRange(codeBlock) else { return }
        // swift-markdown's range starts after the indentation; include it so the
        // whole line is monospace.
        let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
        let full = NSRange(location: lineStart, length: range.upperBound - lineStart)
        container(NSRange(location: lineStart, length: trimmedLength(full)), .codeBlock)
    }

    /// Length without a trailing line break.
    private func trimmedLength(_ range: NSRange) -> Int {
        (source.substring(with: range).trimmingCharacters(in: .newlines) as NSString).length
    }
}
