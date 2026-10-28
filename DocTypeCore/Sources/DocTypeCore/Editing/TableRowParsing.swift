// Splitting one table row into cells by its pipes (an escaped `\|` isn't one).
// Shared by table styling (MarkdownStyler) and editing (TableEditing).

import Foundation

/// Splitting a table row into cells, shared by styling and editing.
enum TableRowParsing {
    /// The text of each cell and where the pipes are (`\|` is not a pipe). Text
    /// before the first pipe or after the last one is a cell only if it isn't
    /// blank (`a | b` has two cells, `| a | b |` too).
    static func cells(in line: NSRange, of source: NSString) -> (cells: [NSRange], pipes: [Int]) {
        var pipes: [Int] = []
        var backslashes = 0
        for location in line.location..<line.upperBound {
            let character = source.character(at: location)
            if character == 124, backslashes % 2 == 0 { pipes.append(location) }  // "|"
            backslashes = character == 92 ? backslashes + 1 : 0  // "\"
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
}