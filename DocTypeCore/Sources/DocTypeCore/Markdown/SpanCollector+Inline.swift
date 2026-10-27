// Inline styles (bold, italic, strikethrough, code, links), list and task markers,
// and table pipes.
//
// Inline markers (`**`, `` ` ``, `[`, `](url)`) behave like block markers: shown
// dimmed on the cursor's line, hidden elsewhere. List bullets and task boxes are
// different: they keep their width and the editor draws a bullet or checkbox over
// them on every line, so text never shifts. Like quotes, a list marker only counts
// once a space follows it (`-` alone stays plain text).

import Foundation
import Markdown

extension SpanCollector {
    mutating func inline(_ local: NSRange, _ style: Style) {
        guard local.length > 0 else { return }
        inlineSpans.append(StyleSpan(shifted(local), style))
    }

    /// A marker that's always shown, dimmed (table pipes).
    mutating func dimmed(_ local: NSRange) {
        guard local.length > 0 else { return }
        markerSpans.append(StyleSpan(shifted(local), .syntaxMarker))
    }

    mutating func hidden(_ local: NSRange) {
        guard local.length > 0 else { return }
        markerSpans.append(StyleSpan(shifted(local), .hiddenMarker))
    }

    /// Styles `range` and marks `length` characters at each end as syntax.
    private mutating func delimited(_ range: NSRange, _ style: Style, delimiterLength length: Int) {
        guard range.length > 2 * length else { return }
        inline(range, style)
        marker(NSRange(location: range.location, length: length))
        marker(NSRange(location: range.upperBound - length, length: length))
    }

    /// Number of `character`s in a row at `location` (for ``code`` or ~~strike~~).
    private func run(of character: unichar, at location: Int) -> Int {
        var end = location
        while end < source.length, source.character(at: end) == character { end += 1 }
        return end - location
    }

    // MARK: - Inline

    mutating func visitStrong(_ strong: Strong) {
        if let range = localRange(strong) { delimited(range, .strong, delimiterLength: 2) }
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        if let range = localRange(emphasis) { delimited(range, .emphasis, delimiterLength: 1) }
        descendInto(emphasis)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        if let range = localRange(strikethrough) {
            delimited(range, .strikethrough, delimiterLength: min(run(of: 126, at: range.location), 2))  // "~"
        }
        descendInto(strikethrough)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let range = localRange(inlineCode) else { return }
        delimited(range, .inlineCode, delimiterLength: run(of: 96, at: range.location))  // "`"
    }

    /// `[text](url)`: the text is styled as a link; `[` and `](url)` are markers.
    /// `<url>` hides its angle brackets; a bare URL is all link text.
    mutating func visitLink(_ link: Link) {
        defer { descendInto(link) }
        guard let range = localRange(link),
              let first = link.children.first(where: { _ in true }).flatMap(localRange),
              let last = Array(link.children).last.flatMap(localRange) else { return }
        let label = NSRange(location: first.location, length: last.upperBound - first.location)
        inline(label, .link)
        marker(NSRange(location: range.location, length: label.location - range.location))
        marker(NSRange(location: label.upperBound, length: range.upperBound - label.upperBound))
    }

    // MARK: - Lists

    mutating func visitListItem(_ listItem: ListItem) {
        defer { descendInto(listItem) }
        guard let range = localRange(listItem) else { return }
        let line = lineWithoutBreak(containing: range.location)
        let text = source.substring(with: line) as NSString
        // The marker counts only with a space after it.
        let markerMatch = text.range(of: "^[ \\t]*([-*+]|[0-9]{1,9}[.)])[ \\t]+", options: .regularExpression)
        guard markerMatch.location != NSNotFound else { return }
        let indentation = text.range(of: "^[ \\t]*", options: .regularExpression).length
        let symbol = text.range(of: "([-*+]|[0-9]{1,9}[.)])", options: .regularExpression,
                                range: NSRange(location: indentation, length: text.length - indentation))
        let symbolRange = NSRange(location: line.location + symbol.location, length: symbol.length)

        let afterMarker = NSRange(location: markerMatch.length, length: text.length - markerMatch.length)
        let box = text.range(of: "^\\[[ xX]\\][ \\t]", options: [.regularExpression, .anchored], range: afterMarker)
        if listItem.checkbox != nil, box.location != NSNotFound {
            // Task: "- " is hidden, "[ ]" is drawn as a checkbox.
            let checked = listItem.checkbox == .checked
            hidden(NSRange(location: symbolRange.location, length: line.location + markerMatch.length - symbolRange.location))
            inline(NSRange(location: line.location + box.location, length: 3), .taskBox(checked: checked))
            if checked {
                let textStart = line.location + box.upperBound
                inline(NSRange(location: textStart, length: range.upperBound - textStart), .completedTask)
            }
        } else if (source.character(at: symbolRange.location) >= 48 && source.character(at: symbolRange.location) <= 57) {
            inline(symbolRange, .listNumber)
        } else {
            inline(symbolRange, .listBullet)
        }
    }

    // MARK: - Tables

    /// Tables stay readable as text: pipes and the `|---|` row are dimmed, never hidden.
    mutating func visitTable(_ table: Table) {
        defer { descendInto(table) }
        guard let range = localRange(table) else { return }
        var lines: [NSRange] = []
        source.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            lines.append(lineRange)
        }
        for (index, line) in lines.enumerated() {
            if index == 1 {
                dimmed(line)  // the |---|---| delimiter row
                continue
            }
            for offset in 0..<line.length where source.character(at: line.location + offset) == 124 {  // "|"
                dimmed(NSRange(location: line.location + offset, length: 1))
            }
        }
    }
}
