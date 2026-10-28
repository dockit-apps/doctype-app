// Images in the open note: finding their files, measuring them before the note
// appears, redrawing when thumbnails arrive or the editor's width changes, and
// resizing by dragging the handle (written back as "alt|width", one undo step).

import AppKit
import DocTypeCore

extension EditorController {
    /// Where `path`'s images are: paths are relative to the note's folder (a
    /// leading "/" means the library root), like links. Web images aren't loaded.
    func imageContext(forNote path: String) -> ImageContext? {
        guard let root = library?.root else { return nil }
        return ImageContext(resolve: { source in
            guard case .external(let url) = LinkTarget.resolve(source, fromNote: path, libraryRoot: root),
                  url.isFileURL else { return nil }
            return url
        }, maxWidth: 600)
    }

    /// Measures the images in `spans` (off the main thread), so the note opens at
    /// its final layout. Re-reads them, in case a file changed since last time.
    func measureImages(in spans: [StyleSpan], context: ImageContext?) async {
        guard let context else { return }
        let urls = spans.compactMap { span -> URL? in
            guard case .image(let source, _) = span.style else { return nil }
            return context.resolve(source)
        }
        if !urls.isEmpty { await ImageStore.shared.loadInfo(urls, refresh: true) }
    }

    func setUpImages() {
        styler.onUnmeasuredImages = { [weak self] urls, range in
            Task { [weak self] in
                await ImageStore.shared.loadInfo(urls)
                guard let self, let storage = self.textView.textStorage else { return }
                self.styler.restyle([StyleApplier.clamp(range, toLength: storage.length)], in: storage)
            }
        }
        NotificationCenter.default.addObserver(forName: ImageStore.thumbnailReady, object: nil, queue: .main) { [weak self] note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated { self?.redrawImages { $0.url == url } }
        }
        // A narrower editor can make images smaller: re-measure them after a resize.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editorWidthChanged() }
        }
        textView.onAttach = { [weak self] items, location in self?.attach(items, at: location) }
        textView.onImageResize = { [weak self] range, width, isFinished in
            self?.resizeImage(at: range, to: width, isFinished: isFinished)
        }
    }

    /// Restyles the lines holding images that match `predicate`.
    private func redrawImages(where predicate: (ImageAttribute) -> Bool) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(EditorTheme.imageKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let image = value as? ImageAttribute, predicate(image) { ranges.append(range) }
        }
        if !ranges.isEmpty { styler.restyle(ranges, in: storage) }
    }

    private func editorWidthChanged() {
        let width = textView.frame.width
        guard abs(width - lastLayoutWidth) >= 1 else { return }
        lastLayoutWidth = width
        widthChangeTask?.cancel()
        widthChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.redrawImages { _ in true }
        }
    }

    /// Dragging a resize handle: shows the new width live, and on release writes
    /// it into the image's alt text as one undoable edit.
    func resizeImage(at range: NSRange, to width: CGFloat, isFinished: Bool) {
        guard let storage = textView.textStorage else { return }
        guard isFinished else {
            styler.previewImageWidth(width, at: range.location, in: storage)
            return
        }
        styler.imageContext?.widthOverride = nil
        if let edit = ImageSizing.edit(settingWidth: Int(width.rounded()), forImageAt: range, in: storage.mutableString,
                                       selection: textView.selectedRange()) {
            apply(edit)
        } else {
            styler.restyle([range], in: storage)
        }
    }
}
