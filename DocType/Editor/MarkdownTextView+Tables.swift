// Where things are in the editor's drawn tables: the "+" buttons, the cell
// under a click, a cell's text frame (for laying the cell editor over it), and
// the table items of the context menu. See MarkdownTextView.

import AppKit
import DocTypeCore

extension MarkdownTextView {
    /// The table "+" button under `point`: what it does and a location in the row it's on.
    func tableButtonHit(at point: NSPoint) -> (operation: TableOperation, location: Int)? {
        guard let (fragment, inFragment) = decoratedFragment(at: point) else { return nil }
        guard let button = fragment.tableButtons.first(where: { $0.frame.insetBy(dx: -3, dy: -3).contains(inFragment) })
        else { return nil }
        guard let layout = textLayoutManager else { return nil }
        let rowStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        var lineEnd = 0
        (string as NSString).getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: NSRange(location: rowStart, length: 0))
        switch button.button {
        case .addRow: return (.addRowBelow, rowStart)
        case .addColumn: return (.addColumnRight, max(rowStart, lineEnd - 1))  // the last cell
        }
    }

    /// The table cell under `point`: where it starts in the text (just after its
    /// opening pipe) and its area, grid lines to grid lines (view coordinates).
    func tableCellHit(at point: NSPoint) -> (location: Int, frame: CGRect)? {
        guard let (fragment, inFragment) = decoratedFragment(at: point), let row = fragment.tableRow,
              !row.isDelimiter, inFragment.y >= 0, inFragment.y <= row.height, let layout = textLayoutManager
        else { return nil }
        let rowStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        let origin = fragmentOrigin(fragment)
        for (index, cell) in row.cells.enumerated() {
            let column = min(index, row.columnLines.count - 2)
            let area = CGRect(x: row.columnLines[column], y: 0,
                              width: row.columnLines[column + 1] - row.columnLines[column], height: row.height)
            guard area.contains(inFragment) else { continue }
            return (rowStart + cell.range.location, area.offsetBy(dx: origin.x, dy: origin.y))
        }
        return nil
    }

    /// Where the text of the table cell starting at `location` goes (view
    /// coordinates), and the cell's layout. Lays the row out first if needed.
    func tableCellTextFrame(at location: Int) -> (frame: CGRect, cell: TableRowLayout.Cell)? {
        guard let layout = textLayoutManager, let start = layOutTable(through: location),
              let fragment = layout.textLayoutFragment(for: start) as? DecoratedLayoutFragment,
              let row = fragment.tableRow else { return nil }
        let rowStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        guard let cell = row.cells.first(where: { rowStart + $0.range.location == location }) else { return nil }
        let origin = fragmentOrigin(fragment)
        return (cell.frame.offsetBy(dx: origin.x, dy: origin.y), cell)
    }

    /// The cell of the table row holding `location` that is under `x` (view
    /// coordinates), by where it starts in the text.
    func tableCell(inRowAt location: Int, x: CGFloat) -> Int? {
        guard let layout = textLayoutManager, let start = layOutTable(through: location),
              let fragment = layout.textLayoutFragment(for: start) as? DecoratedLayoutFragment,
              let row = fragment.tableRow, !row.cells.isEmpty else { return nil }
        let rowStart = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        let inRow = x - fragmentOrigin(fragment).x
        let column = (row.columnLines.indices.dropFirst().first { inRow < row.columnLines[$0] } ?? row.columnLines.count - 1) - 1
        return rowStart + row.cells[min(max(column, 0), row.cells.count - 1)].range.location
    }

    /// Where the cursor is across, in view coordinates.
    var caretX: CGFloat {
        guard let window else { return 0 }
        let onScreen = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
        return convert(window.convertFromScreen(onScreen), from: nil).minX
    }

    /// Lays out the table row at `location` where it's drawn, and returns that
    /// location. Restyling a table drops its rows' layout, and a row laid out on
    /// its own is placed by an estimate (a line off, after a row grew): the
    /// viewport's layout, which drawing uses, places it after the text above.
    func layOutTable(through location: Int) -> NSTextLocation? {
        guard let layout = textLayoutManager, let storage = textStorage, location <= storage.length,
              let target = layout.location(layout.documentRange.location, offsetBy: location) else { return nil }
        let viewport = layout.textViewportLayoutController
        viewport.layoutViewport()
        if viewport.viewportRange?.contains(target) == true { return target }
        // Off screen: from the table's first row, which is close enough.
        let text = storage.mutableString
        var firstRow = text.paragraphRange(for: NSRange(location: min(location, max(storage.length - 1, 0)), length: 0)).location
        while firstRow > 0, storage.attribute(EditorTheme.tableRowKey, at: firstRow - 1, effectiveRange: nil) is TableRowLayout {
            firstRow = text.paragraphRange(for: NSRange(location: firstRow - 1, length: 0)).location
        }
        if let from = layout.location(layout.documentRange.location, offsetBy: firstRow),
           let range = NSTextRange(location: from, end: layout.location(target, offsetBy: 1) ?? target) {
            layout.ensureLayout(for: range)
        }
        return target
    }

    /// A layout fragment's origin in view coordinates.
    func fragmentOrigin(_ fragment: NSTextLayoutFragment) -> CGPoint {
        let container = textContainerOrigin
        return CGPoint(x: container.x + fragment.layoutFragmentFrame.minX, y: container.y + fragment.layoutFragmentFrame.minY)
    }

    /// Puts the table's row and column items at the top of `menu`, acting on the
    /// cell at `location` (also used by the cell editor's menu).
    func addTableItems(to menu: NSMenu, location: Int) {
        let items: [(String, TableOperation)?] = [
            ("Add Row Above", .addRowAbove), ("Add Row Below", .addRowBelow), nil,
            ("Add Column Left", .addColumnLeft), ("Add Column Right", .addColumnRight), nil,
            ("Delete Row", .deleteRow), ("Delete Column", .deleteColumn), nil,
            ("Align Column Left", .align(.left)), ("Align Column Center", .align(.center)),
            ("Align Column Right", .align(.right)), nil,
        ]
        for (index, entry) in items.enumerated() {
            guard let (title, operation) = entry else {
                menu.insertItem(.separator(), at: index)
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(runTableMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TableMenuAction(operation: operation, location: location)
            menu.insertItem(item, at: index)
        }
    }

    /// "Add Column" is off in a table that has all the columns it can get.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runTableMenuItem(_:)) else { return super.validateMenuItem(item) }
        guard let action = item.representedObject as? TableMenuAction,
              action.operation == .addColumnLeft || action.operation == .addColumnRight,
              let storage = textStorage, action.location < storage.length,
              let row = storage.attribute(EditorTheme.tableRowKey, at: action.location, effectiveRange: nil) as? TableRowLayout
        else { return true }
        return row.canAddColumn
    }

    @objc private func runTableMenuItem(_ item: NSMenuItem) {
        guard let action = item.representedObject as? TableMenuAction else { return }
        onTableOperation(action.operation, action.location)
    }
}

/// A table context menu item's operation and the location it was opened at.
private final class TableMenuAction: NSObject {
    let operation: TableOperation
    let location: Int
    init(operation: TableOperation, location: Int) {
        self.operation = operation
        self.location = location
    }
}
