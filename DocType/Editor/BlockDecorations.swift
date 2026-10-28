// Draws decorations behind and over the text, the way chat apps and Obsidian do:
// code blocks as one rounded box, block quotes with a bar on the left, `---` as a
// horizontal rule, list bullets as "•", tasks as checkboxes, images under the
// line that holds their syntax, and tables as a grid with "+" buttons.
//
// TextKit 2 lays out each paragraph in its own layout fragment. EditorTheme marks
// lines and characters with attributes; this delegate reads them and returns a
// fragment that paints the decorations. One fragment class handles all of them,
// so a line can have several (a task inside a quote).

import AppKit
import DocTypeCore

final class BlockDecorations: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else {
            return NSTextLayoutFragment(textElement: textElement, range: range)
        }
        let string = paragraph.attributedString
        let lineAttributes = string.attributes(at: 0, effectiveRange: nil)
        var decorations = Decorations()
        if let raw = lineAttributes[EditorTheme.codeBlockLineKey] as? Int {
            decorations.codeBlock = CodeBlockLinePosition(rawValue: raw)
        }
        decorations.quote = lineAttributes[EditorTheme.quoteLineKey] != nil
        decorations.rule = lineAttributes[EditorTheme.ruleLineKey] != nil
        decorations.tableRow = lineAttributes[EditorTheme.tableRowKey] as? TableRowLayout
        let whole = NSRange(location: 0, length: string.length)
        string.enumerateAttribute(EditorTheme.bulletKey, in: whole) { value, markRange, _ in
            if value != nil { decorations.marks.append(ListMark(range: markRange, kind: .bullet)) }
        }
        string.enumerateAttribute(EditorTheme.taskKey, in: whole) { value, markRange, _ in
            if let checked = value as? Bool { decorations.marks.append(ListMark(range: markRange, kind: .task(checked: checked))) }
        }
        string.enumerateAttribute(EditorTheme.imageKey, in: whole) { value, imageRange, _ in
            if let image = value as? ImageAttribute { decorations.images.append(ImageMark(image: image, range: imageRange)) }
        }
        guard decorations.isNeeded else { return NSTextLayoutFragment(textElement: textElement, range: range) }
        return DecoratedLayoutFragment(textElement: textElement, range: range, decorations: decorations)
    }
}

/// Where a line sits in its code block; decides which corners of the box are rounded.
nonisolated enum CodeBlockLinePosition: Int {
    case first, middle, last, only
}

nonisolated struct ListMark {
    enum Kind { case bullet, task(checked: Bool) }
    /// Range of the marker characters within the paragraph.
    let range: NSRange
    let kind: Kind
}

nonisolated struct ImageMark {
    let image: ImageAttribute
    /// Range of the image's syntax within the paragraph.
    let range: NSRange
}

nonisolated struct Decorations {
    var codeBlock: CodeBlockLinePosition?
    var quote = false
    var rule = false
    var marks: [ListMark] = []
    var images: [ImageMark] = []
    var tableRow: TableRowLayout?
    var isNeeded: Bool { codeBlock != nil || quote || rule || !marks.isEmpty || !images.isEmpty || tableRow != nil }
}

/// `nonisolated`: TextKit 2 may lay out and draw fragments off the main thread.
nonisolated final class DecoratedLayoutFragment: NSTextLayoutFragment {
    private let decorations: Decorations

    private static let codeFill = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.045)
    private static let codeBorder = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.10)
    private static let cornerRadius: CGFloat = 8
    /// Body text metrics, for centering bullets and checkboxes on a line.
    private static let bodyMetrics: (xHeight: CGFloat, capHeight: CGFloat) = {
        let font = NSFont.systemFont(ofSize: 15)
        return (font.xHeight, font.capHeight)
    }()

    init(textElement: NSTextElement, range: NSTextRange?, decorations: Decorations) {
        self.decorations = decorations
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        decorations = Decorations()
        super.init(coder: coder)
    }

    /// The text container's full width, in fragment coordinates. A fragment's own
    /// frame is only as wide as its text and starts at the indent.
    private var fullWidth: CGRect {
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.maxX
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
    }

    /// The lines holding this paragraph's text. When the note ends with a line
    /// break, TextKit adds an extra, empty line for the cursor to the last
    /// paragraph's fragment, below its paragraph spacing; images are placed
    /// without it.
    private var textLines: ArraySlice<NSTextLineFragment> {
        guard textLineFragments.count > 1, let last = textLineFragments.last, last.characterRange.length == 0
        else { return textLineFragments[...] }
        return textLineFragments.dropLast()
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = imageFrames.reduce(super.renderingSurfaceBounds.union(fullWidth)) { $0.union($1.frame.insetBy(dx: -4, dy: -4)) }
        // A table may be wider than the text, and a note's last row is drawn
        // below its fragment (TextKit leaves out a last paragraph's spacing).
        if let row = decorations.tableRow {
            bounds = bounds.union(CGRect(x: -1, y: 0, width: (row.columnLines.last ?? 0) + 2, height: row.height + 1))
        }
        return tableButtons.reduce(bounds) { $0.union($1.frame.insetBy(dx: -2, dy: -2)) }
    }

    // MARK: - Tables

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

    private func drawTableRow(_ row: TableRowLayout, at point: CGPoint, _ context: CGContext) {
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

    // MARK: - Images

    /// Where each image is drawn, in fragment coordinates: stacked under the
    /// paragraph's text, starting where the text starts.
    var imageFrames: [(mark: ImageMark, frame: CGRect)] {
        guard !decorations.images.isEmpty else { return [] }
        let x = textLineFragments.first?.typographicBounds.minX ?? 0
        var y = (textLines.last?.typographicBounds.maxY ?? 0) + EditorTheme.imageGap
        return decorations.images.map { mark in
            defer { y += mark.image.size.height + EditorTheme.imageGap }
            return (mark, CGRect(origin: CGPoint(x: x, y: y), size: mark.image.size))
        }
    }

    /// The square at an image's bottom-right corner that resizes it.
    static func resizeHandle(of frame: CGRect) -> CGRect {
        CGRect(x: frame.maxX - 5, y: frame.maxY - 5, width: 10, height: 10)
    }

    private func drawImages(at point: CGPoint, _ context: CGContext) {
        let scale = (NSScreen.main?.backingScaleFactor ?? 2)
        for (mark, frame) in imageFrames {
            let rect = frame.offsetBy(dx: point.x, dy: point.y)
            let clip = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            let maxPixels = Int((max(rect.width, rect.height) * scale / 256).rounded(.up)) * 256
            context.saveGState()
            context.addPath(clip)
            context.clip()
            if let image = ImageStore.shared.thumbnail(for: mark.image.url, maxPixelSize: maxPixels) {
                // The view is flipped; CGImages draw bottom-up.
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            } else {
                context.setFillColor(NSColor.quaternarySystemFill.cgColor)
                context.fill(rect)
            }
            context.restoreGState()

            guard mark.image.isSelected else { continue }
            context.saveGState()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2)
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerWidth: 7, cornerHeight: 7, transform: nil))
            context.strokePath()
            let handle = Self.resizeHandle(of: rect)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: handle)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: handle.insetBy(dx: 0.75, dy: 0.75))
            context.restoreGState()
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let area = fullWidth.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        if let position = decorations.codeBlock { drawCodeBox(in: area.insetBy(dx: 0.5, dy: 0), position: position, context) }
        if decorations.quote {
            context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            context.fill(CGRect(x: area.minX + 2, y: area.minY, width: 3, height: area.height))
        }
        if decorations.rule {
            context.setFillColor(NSColor.separatorColor.cgColor)
            context.fill(CGRect(x: area.minX, y: area.minY + (area.height / 2).rounded(), width: area.width, height: 1))
        }
        context.restoreGState()
        if let row = decorations.tableRow { drawTableRow(row, at: point, context) }
        super.draw(at: point, in: context)
        for mark in decorations.marks { draw(mark, at: point, context) }
        drawImages(at: point, context)
    }

    // MARK: - Bullets and checkboxes

    private func draw(_ mark: ListMark, at point: CGPoint, _ context: CGContext) {
        guard let line = textLineFragments.first(where: { NSLocationInRange(mark.range.location, $0.characterRange) })
        else { return }
        let start = line.locationForCharacter(at: mark.range.location)
        let end = line.locationForCharacter(at: mark.range.upperBound)
        let centerX = point.x + line.typographicBounds.minX + (start.x + end.x) / 2
        let baseline = point.y + line.typographicBounds.minY + line.glyphOrigin.y

        context.saveGState()
        switch mark.kind {
        case .bullet:
            let size: CGFloat = 5.5
            let centerY = baseline - Self.bodyMetrics.xHeight / 2
            context.setFillColor(NSColor.secondaryLabelColor.cgColor)
            context.fillEllipse(in: CGRect(x: centerX - size / 2, y: centerY - size / 2, width: size, height: size))
        case .task(let checked):
            let size: CGFloat = 14
            let centerY = baseline - Self.bodyMetrics.capHeight / 2
            let box = CGRect(x: centerX - size / 2, y: centerY - size / 2, width: size, height: size)
            let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
            if checked {
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                context.addPath(path)
                context.fillPath()
                // Checkmark (y grows downward in the editor's flipped coordinates).
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(1.8)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.move(to: CGPoint(x: box.minX + 3.5, y: box.midY + 0.5))
                context.addLine(to: CGPoint(x: box.minX + 6, y: box.maxY - 3.5))
                context.addLine(to: CGPoint(x: box.maxX - 3.2, y: box.minY + 3.8))
                context.strokePath()
            } else {
                context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
                context.setLineWidth(1.3)
                context.addPath(CGPath(roundedRect: box.insetBy(dx: 0.65, dy: 0.65), cornerWidth: 3.5, cornerHeight: 3.5,
                                       transform: nil))
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    // MARK: - Code box

    /// The line's part of the box: rounded corners only at the block's first and
    /// last lines, and a border on the outer edges only, so the lines join up.
    private func drawCodeBox(in box: CGRect, position: CodeBlockLinePosition, _ context: CGContext) {
        let roundTop = position == .first || position == .only
        let roundBottom = position == .last || position == .only
        let top = roundTop ? min(Self.cornerRadius, box.height / 2) : 0
        let bottom = roundBottom ? min(Self.cornerRadius, box.height / 2) : 0

        // In the flipped view, minY is the top edge.
        let fill = CGMutablePath()
        fill.move(to: CGPoint(x: box.minX + top, y: box.minY))
        fill.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.maxY), radius: top)
        fill.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.maxY), radius: bottom)
        fill.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.minY), radius: bottom)
        fill.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY), radius: top)
        fill.closeSubpath()
        context.addPath(fill)
        context.setFillColor(Self.codeFill.cgColor)
        context.fillPath()

        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: box.minX, y: box.minY + top))
        outline.addLine(to: CGPoint(x: box.minX, y: box.maxY - bottom))
        if roundBottom {
            outline.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX + bottom, y: box.maxY), radius: bottom)
            outline.addLine(to: CGPoint(x: box.maxX - bottom, y: box.maxY))
            outline.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX, y: box.maxY - bottom), radius: bottom)
        } else {
            outline.move(to: CGPoint(x: box.maxX, y: box.maxY))
        }
        outline.addLine(to: CGPoint(x: box.maxX, y: box.minY + top))
        if roundTop {
            outline.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX - top, y: box.minY), radius: top)
            outline.addLine(to: CGPoint(x: box.minX + top, y: box.minY))
            outline.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX, y: box.minY + top), radius: top)
        }
        context.addPath(outline)
        context.setStrokeColor(Self.codeBorder.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    private static func dynamic(light: Int, dark: Int, alpha: CGFloat) -> NSColor {
        EditorTheme.dynamic(light: light, dark: dark, alpha: alpha)
    }
}
