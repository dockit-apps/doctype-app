// Draws code blocks as one rounded, full-width box, like code in chat apps.
//
// TextKit 2 lays out each paragraph in its own layout fragment. For lines that
// EditorTheme marked as code, this delegate returns a fragment that paints the
// box behind its text: rounded top corners on the first line, rounded bottom
// corners on the last, straight edges in between, so the lines join up.

import AppKit

final class CodeBlockLayout: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let raw = paragraph.attributedString.attribute(EditorTheme.codeBlockLineKey, at: 0, effectiveRange: nil) as? Int,
           let position = CodeBlockLinePosition(rawValue: raw) {
            return CodeBlockLayoutFragment(textElement: textElement, range: range, position: position)
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}

/// `nonisolated`: TextKit 2 may lay out and draw fragments off the main thread.
nonisolated final class CodeBlockLayoutFragment: NSTextLayoutFragment {
    private static let cornerRadius: CGFloat = 8
    private static let fill = EditorTheme.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.045)
    private static let border = EditorTheme.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.10)

    private let position: CodeBlockLinePosition

    init(textElement: NSTextElement, range: NSTextRange?, position: CodeBlockLinePosition) {
        self.position = position
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        position = .middle
        super.init(coder: coder)
    }

    /// The box spans the text container's full width. A fragment's own frame is only
    /// as wide as its text and starts at the indent, so it can't be used directly.
    private var boxInFragmentCoordinates: CGRect {
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.maxX
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(boxInFragmentCoordinates)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let box = boxInFragmentCoordinates.offsetBy(dx: point.x, dy: point.y).insetBy(dx: 0.5, dy: 0)
        let roundTop = position == .first || position == .only
        let roundBottom = position == .last || position == .only
        context.saveGState()
        context.addPath(Self.fillPath(box, roundTop: roundTop, roundBottom: roundBottom))
        context.setFillColor(Self.fill.cgColor)
        context.fillPath()
        context.addPath(Self.outlinePath(box, roundTop: roundTop, roundBottom: roundBottom))
        context.setStrokeColor(Self.border.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    /// The line's part of the box, closed, with rounded corners only at the block's ends.
    private static func fillPath(_ box: CGRect, roundTop: Bool, roundBottom: Bool) -> CGPath {
        let path = CGMutablePath()
        let top = roundTop ? min(cornerRadius, box.height / 2) : 0
        let bottom = roundBottom ? min(cornerRadius, box.height / 2) : 0
        // In the flipped view, minY is the top edge.
        path.move(to: CGPoint(x: box.minX + top, y: box.minY))
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.maxY), radius: top)
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.maxY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.minY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY), radius: top)
        path.closeSubpath()
        return path
    }

    /// The border: the sides always, the top and bottom edges only at the block's
    /// ends, so no lines are drawn between the lines of code.
    private static func outlinePath(_ box: CGRect, roundTop: Bool, roundBottom: Bool) -> CGPath {
        let path = CGMutablePath()
        let top = roundTop ? min(cornerRadius, box.height / 2) : 0
        let bottom = roundBottom ? min(cornerRadius, box.height / 2) : 0
        // Left side, from the top down.
        path.move(to: CGPoint(x: box.minX, y: box.minY + top))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY - bottom))
        if roundBottom {
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX + bottom, y: box.maxY), radius: bottom)
            path.addLine(to: CGPoint(x: box.maxX - bottom, y: box.maxY))
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX, y: box.maxY - bottom), radius: bottom)
        } else {
            path.move(to: CGPoint(x: box.maxX, y: box.maxY))
        }
        // Right side, from the bottom up.
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY + top))
        if roundTop {
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX - top, y: box.minY), radius: top)
            path.addLine(to: CGPoint(x: box.minX + top, y: box.minY))
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX, y: box.minY + top), radius: top)
        }
        return path
    }
}
