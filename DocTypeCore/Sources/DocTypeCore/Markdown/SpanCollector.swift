// Walks one text block's markdown tree (from swift-markdown) and records style
// spans in document coordinates. Block-level constructs live here; inline styles,
// lists and tables are in SpanCollector+Inline.swift.

import Foundation
import Markdown

/// Walks one block's markdown tree and records spans in document coordinates.
struct SpanCollector: MarkupWalker {
    let source: NSString
    let mapping: SourceMapping
    let base: Int
    var containerSpans: [StyleSpan] = []
    var inlineSpans: [StyleSpan] = []
    var markerSpans: [StyleSpan] = []
    /// True while visiting a link's children, whose text is already linked.
    var isInsideLink = false

    /// The node's range relative to the block (not yet shifted by `base`).
    func localRange(_ markup: Markup) -> NSRange? {
        markup.range.map { mapping.range(of: $0, base: 0) }
    }

    /// Adds a marker that shows while the cursor is on its line (or in `revealIn`).
    mutating func marker(_ local: NSRange, revealIn reveal: NSRange? = nil, unconfirmedIn unconfirmed: NSRange? = nil) {
        guard local.length > 0 else { return }
        let line = reveal ?? lineWithoutBreak(containing: local.location)
        markerSpans.append(StyleSpan(NSRange(location: base + local.location, length: local.length), .syntaxMarker,
                                     revealRange: shifted(line), unconfirmedRange: unconfirmed.map(shifted)))
    }

    func shifted(_ local: NSRange) -> NSRange {
        NSRange(location: base + local.location, length: local.length)
    }

    /// The line's range if its text doesn't end with a space or tab yet, i.e. the
    /// syntax isn't confirmed while the cursor is on it; nil once it is.
    func unconfirmedLine(containing location: Int) -> NSRange? {
        let line = lineWithoutBreak(containing: location)
        guard line.length > 0 else { return line }
        let last = source.character(at: line.upperBound - 1)
        return last == 32 || last == 9 ? nil : line  // space, tab
    }

    func lineWithoutBreak(containing location: Int) -> NSRange {
        var start = 0, contentsEnd = 0
        source.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    mutating func container(_ local: NSRange, _ style: Style, unconfirmedIn unconfirmed: NSRange? = nil) {
        containerSpans.append(StyleSpan(shifted(local), style, unconfirmedRange: unconfirmed.map(shifted)))
    }

    mutating func visitHeading(_ heading: Heading) {
        defer { descendInto(heading) }  // inline styles inside the heading text
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
            // Setext heading: the ==== or ---- underline is the last line of the range.
            // While you're typing the underline it's unconfirmed, so starting a "-"
            // list under a line of text doesn't flash a big heading.
            let lastLine = source.lineRange(for: NSRange(location: max(range.upperBound - 1, range.location), length: 0))
            let underline = (source.substring(with: lastLine) as NSString).trimmingCharacters(in: .newlines) as NSString
            let unconfirmed = unconfirmedLine(containing: lastLine.location)
            container(range, .heading(level: heading.level), unconfirmedIn: unconfirmed)
            marker(NSRange(location: lastLine.location, length: underline.length),
                   revealIn: NSRange(location: range.location, length: lastLine.location + underline.length - range.location),
                   unconfirmedIn: unconfirmed)
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        guard let range = localRange(blockQuote) else { return }
        // A quote needs "> ": a lone ">" or ">text" stays plain text.
        let firstLine = source.substring(with: lineWithoutBreak(containing: range.location)) as NSString
        guard firstLine.range(of: "^ {0,3}>[ \\t]", options: .regularExpression).location != NSNotFound else {
            descendInto(blockQuote)
            return
        }
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
                // Always hidden: the quote bar shows instead (see QuoteEditing).
                markerSpans.append(StyleSpan(shifted(NSRange(location: lineRange.location + quote.location,
                                                             length: quote.length)), .hiddenMarker))
            }
        }
        descendInto(blockQuote)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        guard let range = localRange(thematicBreak) else { return }
        let line = NSRange(location: range.location, length: trimmedLength(range))
        let unconfirmed = unconfirmedLine(containing: line.location)
        container(line, .horizontalRule, unconfirmedIn: unconfirmed)
        marker(line, unconfirmedIn: unconfirmed)
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
    func trimmedLength(_ range: NSRange) -> Int {
        (source.substring(with: range).trimmingCharacters(in: .newlines) as NSString).length
    }
}
