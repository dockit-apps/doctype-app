// Splitting one table row into cells by its pipes (an escaped `\|` isn't one).
// Shared by table styling (MarkdownStyler) and editing (TableEditing).

import Foundation

/// Splitting a table row into cells, shared by styling and editing.
enum TableRowParsing {
    /// The text of each cell and where the pipes are (`\|` is not a pipe, nor `\\|`). Text
    /// before the first pipe or after the last one is a cell only if it isn't
    /// blank (`a | b` has two cells, `| a | b |` too).
    static func cells(in line: NSRange, of source: NSString) -> (cells: [NSRange], pipes: [Int]) {
        var pipes: [Int] = []
        var previous: unichar = 0
        for location in line.location..<line.upperBound {
            let character = source.character(at: location)
            // A "|" after any backslash, even "\\|", isn't a pipe for cmark-gfm.
            if character == 124, previous != 92 { pipes.append(location) }
            previous = character
        }
        let bounds = [line.location - 1] + pipes + [line.upperBound]
        func isBlank(_ range: NSRange) -> Bool {
            source.substring(with: range).allSatisfy { $0 == " " || $0 == "\t" }
        }
        var cells: [NSRange] = []
        for index in 0..<(bounds.count - 1) {
            let cell = NSRange(location: bounds[index] + 1, length: bounds[index + 1] - bounds[index] - 1)
            let isEdge = index == 0 || index == bounds.count - 2
            if isEdge, isBlank(cell) { continue }
            cells.append(cell)
        }
        return (cells, pipes)
    }

    /// The rows of a table cmark-gfm parsed at `range` of `source`, one line
    /// each, the header row first. Nil if there's no `|---|` row in it.
    static func rows(ofTableAt range: NSRange, in source: NSString) -> [NSRange]? {
        var lines: [NSRange] = []
        source.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            lines.append(lineRange)
        }
        // Right after a paragraph, cmark-gfm starts the table at the paragraph's
        // first line; the table really starts on the line before the `|---|` row.
        guard let delimiter = lines.firstIndex(where: { TableEditing.isDelimiterRow($0, in: source) }),
              delimiter >= 1 else { return nil }
        return Array(lines[(delimiter - 1)...])
    }
}