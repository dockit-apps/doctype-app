// Inline styles (bold, italic, strikethrough, code, links, bare URLs), list and
// task markers, and table pipes.
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
    /// `<url>` hides its angle brackets.
    mutating func visitLink(_ link: Link) {
        let wasInsideLink = isInsideLink
        isInsideLink = true
        defer {
            descendInto(link)
            isInsideLink = wasInsideLink
        }
        guard let range = localRange(link),
              let first = link.children.first(where: { _ in true }).flatMap(localRange),
              let last = Array(link.children).last.flatMap(localRange) else { return }
        let label = NSRange(location: first.location, length: last.upperBound - first.location)
        inline(label, .link(destination: link.destination ?? ""))
        marker(NSRange(location: range.location, length: label.location - range.location))
        marker(NSRange(location: label.upperBound, length: range.upperBound - label.upperBound))
    }

    /// `![alt](source)`: one span for the whole syntax; the alt text isn't styled.
    mutating func visitImage(_ image: Image) {
        guard let range = localRange(image), range.length > 0, !isInsideLink else { return }
        let alt = Array(image.children).compactMap { ($0 as? Text)?.string }.joined()
        let width = ImageSizing.parse(alt: alt).width
        let line = lineWithoutBreak(containing: range.location)
        inlineSpans.append(StyleSpan(shifted(range), .image(source: image.source ?? "", width: width),
                                     revealRange: shifted(line)))
    }

    /// Bare URLs in text (`https://…`, `www.…`) are links too, as on GitHub.
    /// swift-markdown leaves GFM's autolink extension off, so they're found here.
    mutating func visitText(_ text: Text) {
        guard !isInsideLink, let range = localRange(text), range.length > 0 else { return }
        for url in BareURL.matches(in: source, range: range) {
            let string = source.substring(with: url)
            inline(url, .link(destination: string.hasPrefix("www.") ? "https://" + string : string))
        }
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

    /// Tables look like tables: the editor draws a grid over the (invisible) pipes,
    /// the header row is bold, and the `|---|` row is always hidden (the cursor
    /// skips it, see TableEditing.caretSkippingDelimiterRow; alignment is set
    /// with the table commands). Every cell gets a `.tableCell` span so the editor can
    /// line the columns up, and every row a `.tableRow` span for the grid.
    mutating func visitTable(_ table: Table) {
        defer { descendInto(table) }
        guard let range = localRange(table) else { return }
        var lines: [NSRange] = []
        source.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            lines.append(lineRange)
        }
        let alignments: [TableAlignment] = table.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .right
            default: .left
            }
        }
        // Right after a paragraph, cmark-gfm starts the table at the paragraph's
        // first line; the table really starts on the line before the `|---|` row.
        guard let delimiter = lines.firstIndex(where: { TableEditing.isDelimiterRow($0, in: source) }),
              delimiter >= 1 else { return }
        lines.removeFirst(delimiter - 1)
        guard let firstLine = lines.first, let lastLine = lines.last else { return }
        let tableRange = NSRange(location: firstLine.location, length: lastLine.upperBound - firstLine.location)
        for (index, line) in lines.enumerated() {
            let (cells, pipes) = TableRowParsing.cells(in: line, of: source)
            containerSpans.append(StyleSpan(shifted(line), .tableRow(index: index, isLast: index == lines.count - 1),
                                            revealRange: shifted(tableRange)))
            if index == 1 { hidden(line) }  // the |---|---| delimiter row: never shown
            for pipe in pipes { markerSpans.append(StyleSpan(shifted(NSRange(location: pipe, length: 1)), .tablePipe)) }
            for (column, cell) in cells.enumerated() {
                let alignment = column < alignments.count ? alignments[column] : .left
                // Empty cells ("||") too: they need widening like any other.
                inlineSpans.append(StyleSpan(shifted(cell), .tableCell(row: index, column: column,
                                                                       alignment: alignment)))
                if index == 0 { inline(cell, .strong) }
            }
        }
    }
}
