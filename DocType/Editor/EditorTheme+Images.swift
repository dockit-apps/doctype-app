// Images in the editor. The `![alt](source)` text stays in the note; the picture
// is drawn under its line by BlockDecorations, in space reserved with paragraph
// spacing, so layout, scrolling and the cursor work as for any other line.
// Off the image's line the syntax is hidden; on it, the syntax shows dimmed and
// the image gets a resize handle. An image that can't be shown (missing file, a
// web URL, not measured yet) keeps its syntax visible instead of leaving a gap.

import AppKit
import DocTypeCore

/// What's stored on an image's syntax, for drawing and hit-testing.
nonisolated struct ImageAttribute: Hashable, Sendable {
    let url: URL
    /// Display size in points.
    let size: CGSize
    /// Where the syntax started when styled. Keeps two identical images next to
    /// each other apart (equal values would merge into one attribute run).
    let ordinal: Int
    /// The cursor is on the image's line: the resize handle shows.
    let isSelected: Bool
}

/// What styling needs to show images: where the files are and how wide the editor is.
struct ImageContext {
    /// An image's source (as written) → its file, or nil if it isn't a local file.
    let resolve: (String) -> URL?
    var maxWidth: CGFloat
    /// While a resize handle is dragged: the image (by syntax location) and its live width.
    var widthOverride: (location: Int, width: CGFloat)?
}

extension EditorTheme {
    static let imageKey = NSAttributedString.Key("DocTypeImage")
    /// Space above, between and below images.
    nonisolated static let imageGap: CGFloat = 8
    /// Images without a width in their alt text show at most this wide.
    static let defaultImageWidth: CGFloat = 400

    /// `natural` scaled to `width` (or the default), never wider than `maxWidth`.
    static func displaySize(natural: CGSize, width: CGFloat?, maxWidth: CGFloat) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let target = min(width ?? min(natural.width, defaultImageWidth), maxWidth)
        let displayWidth = max(target, CGFloat(ImageSizing.minimumWidth)).rounded()
        return CGSize(width: displayWidth, height: (displayWidth * natural.height / natural.width).rounded())
    }

    /// Styles one image's syntax. Returns its file if it still needs measuring.
    static func applyImage(_ span: StyleSpan, source: String, width: Int?, to text: NSMutableAttributedString,
                           selection: NSRange, context: ImageContext?) -> URL? {
        let url = context?.resolve(source)
        guard let context, let url, let info = ImageStore.shared.info(for: url) else {
            text.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
            guard let url, !ImageStore.shared.hasFailed(url) else { return nil }
            return url
        }
        var displayWidth = width.map(CGFloat.init)
        if let override = context.widthOverride, override.location == span.range.location { displayWidth = override.width }
        let size = displaySize(natural: info.size, width: displayWidth, maxWidth: context.maxWidth)
        let isSelected = span.isRevealed(by: selection)
        if isSelected {
            text.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
        } else {
            text.addAttributes(concealedAttributes, range: span.range)
        }
        text.addAttribute(imageKey, value: ImageAttribute(url: url, size: size, ordinal: span.range.location,
                                                          isSelected: isSelected), range: span.range)
        return nil
    }

    /// Adds room under each line in `range` that has images: their heights plus gaps.
    static func reserveImageSpace(in range: NSRange, of text: NSMutableAttributedString) {
        var heights: [NSRange: [CGFloat]] = [:]  // paragraph → image heights
        let string = text.mutableString
        text.enumerateAttribute(imageKey, in: range) { value, run, _ in
            guard let image = value as? ImageAttribute else { return }
            heights[string.paragraphRange(for: NSRange(location: run.location, length: 0)), default: []].append(image.size.height)
        }
        for (paragraph, images) in heights {
            let current = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let style = (current ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing += images.reduce(0, +) + imageGap * CGFloat(images.count + 1)
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }
}
