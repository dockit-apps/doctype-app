// Drawing a table row: its grid lines, the shaded header, each cell's wrapped
// text, and the "+" buttons that add a row or column. The layout comes from
// EditorTheme+Tables; see BlockDecorations.

import AppKit
import DocTypeCore

nonisolated extension DecoratedLayoutFragment {
    enum TableButton { case addRow, addColumn }

    private static let tableLine = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.16)
    private static let tableHeaderFill = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.04)
    /// The row of a table drawn by this fragment, if it is one.
    var tableRow: TableRowLayout? { decorations.tableRow }

    /// The table's "+" buttons on this row (fragment coordinates): "add column"
    /// right of the header, "add row" under the last row. Only while the cursor is in the table.
    var tableButtons: [(button: TableButton, frame: CGRect)] {
        guard let row = decorations.tableRow, row.isActive, row.index == 0 || row.isLast,
              let left = row.columnLines.first, let right = row.columnLines.last else { return [] }
        let size: CGFloat = 16
        var buttons: [(TableButton, CGRect)] = []
        if row.index == 0 {
            buttons.append((.addColumn, CGRect(x: right + 6, y: (row.height - size) / 2, width: size, height: size)))
        }
        if row.isLast {
            buttons.append((.addRow, CGRect(x: (left + right - size) / 2, y: row.height + 3, width: size, height: size)))
        }
        return buttons
    }

    func drawTableRow(_ row: TableRowLayout, at point: CGPoint, _ context: CGContext) {
        guard let left = row.columnLines.first, let right = row.columnLines.last else { return }
        let top = point.y
        let bottom = point.y + row.height
        context.saveGState()
        if row.index == 0 {
            context.setFillColor(Self.tableHeaderFill.cgColor)
            context.fill(CGRect(x: point.x + left, y: top, width: right - left, height: bottom - top))
        }
        context.setStrokeColor(Self.tableLine.cgColor)
        context.setLineWidth(1)
        // Lines on whole pixels plus a half, so they're crisp.
        for x in row.columnLines {
            let lineX = (point.x + x).rounded(.down) + 0.5
            context.move(to: CGPoint(x: lineX, y: top))
            context.addLine(to: CGPoint(x: lineX, y: bottom))
        }
        if row.index == 0 {
            context.move(to: CGPoint(x: point.x + left, y: top + 0.5))
            context.addLine(to: CGPoint(x: point.x + right + 1, y: top + 0.5))
        }
        // The |---| row only continues the columns: the header's bottom line is its border.
        if !row.isDelimiter {
            context.move(to: CGPoint(x: point.x + left, y: bottom - 0.5))
            context.addLine(to: CGPoint(x: point.x + right + 1, y: bottom - 0.5))
        }
        context.strokePath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for cell in row.cells where !cell.isEditing && cell.text.length > 0 {
            cell.text.draw(with: cell.frame.offsetBy(dx: point.x, dy: point.y),
                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        NSGraphicsContext.restoreGraphicsState()

        for (_, frame) in tableButtons {
            let circle = frame.offsetBy(dx: point.x, dy: point.y)
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.6)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: circle.midX - 4, y: circle.midY))
            context.addLine(to: CGPoint(x: circle.midX + 4, y: circle.midY))
            context.move(to: CGPoint(x: circle.midX, y: circle.midY - 4))
            context.addLine(to: CGPoint(x: circle.midX, y: circle.midY + 4))
            context.strokePath()
        }
        context.restoreGState()
    }
}
