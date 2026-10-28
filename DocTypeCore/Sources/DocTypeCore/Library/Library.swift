// The library on disk: owns all file I/O and the in-memory index.
// It is an actor, so every file operation runs off the main thread, and the app
// and a future MCP server can share the same API.

import Foundation
import os

public actor Library {
    /// Something changed on disk that the app didn't do itself.
    public enum Change: Sendable, Equatable {
        /// These notes (relative paths) were created, modified or removed.
        /// After a full rescan the set may be empty: check the index.
        case notesChanged(Set<String>)
        /// The library folder itself was moved or deleted.
        case libraryMissing
    }

    public nonisolated let root: URL
    /// Publishes a new index snapshot after every change. One consumer per Library.
    public nonisolated let updates: AsyncStream<LibraryIndex>
    /// Publishes external changes once watching has started. One consumer per Library.
    public nonisolated let changes: AsyncStream<Change>

    public internal(set) var index = LibraryIndex()
    private let updatesContinuation: AsyncStream<LibraryIndex>.Continuation
    private let changesContinuation: AsyncStream<Change>.Continuation
    private var watcher: FolderWatcher?
    private var watchTask: Task<Void, Never>?

    public init(root: URL) {
        self.root = Self.canonicalURL(root)
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (changes, changesContinuation) = AsyncStream.makeStream()
    }

    deinit {
        watcher?.stop()
        watchTask?.cancel()
        updatesContinuation.finish()
        changesContinuation.finish()
    }

    // MARK: - Reading the whole library

    /// Reads the whole library folder and replaces the index.
    public func scan() throws {
        assertNotOnMainThread()
        let state = DocTypeCore.signposter.beginInterval("Library scan")
        defer { DocTypeCore.signposter.endInterval("Library scan", state) }

        let result = try LibraryScanner.scan(root: root)
        index = LibraryIndex(notes: result.notes, folders: result.folders)
        updatesContinuation.yield(index)
    }

    // MARK: - Single notes

    /// The full text of a note, frontmatter included.
    public func read(_ path: String) throws -> String {
        assertNotOnMainThread()
        return try String(contentsOf: url(for: path), encoding: .utf8)
    }

    /// Writes a note atomically (temp file + rename, so a crash never leaves
    /// half a note), then refreshes its index entry from the saved text.
    public func save(_ path: String, text: String) throws {
        assertNotOnMainThread()
        let fileURL = url(for: path)
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        index.update(NoteSummary.make(path: path, text: text, modified: modified ?? Date()))
        updatesContinuation.yield(index)
    }

    /// Saves `text` as a new note next to `path`, named like
    /// `Graphs (conflict 2026-10-27 135210).md`. Used so that resolving a conflict
    /// never throws text away. Falls back to the library root if the note's
    /// folder is gone. Returns the new note's path.
    @discardableResult
    public func saveConflictCopy(of path: String, text: String, date: Date = Date()) throws -> String {
        let folder = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        let folderExists = folder.isEmpty
            || (FileManager.default.fileExists(atPath: url(for: folder).path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let copyPath = FileNaming.conflictCopyPath(for: path, in: folderExists ? folder : "", date: date) { candidate in
            FileManager.default.fileExists(atPath: url(for: candidate).path)
        }
        try save(copyPath, text: text)
        return copyPath
    }

    /// Sends the current index to the app.
    func publishIndex() {
        updatesContinuation.yield(index)
    }

    // MARK: - Watching for external changes

    /// Starts following changes made by other programs. Our own writes are
    /// ignored by FSEvents (`IgnoreSelf`), so saving never looks like an external edit.
    public func startWatching() {
        guard watcher == nil else { return }
        let (batches, batchContinuation) = AsyncStream.makeStream(of: [FolderWatcher.Event].self)
        let watcher = FolderWatcher(root: root) { batchContinuation.yield($0) }
        // One task applies batches in order, so a delete never overtakes the create before it.
        watchTask = Task { [weak self] in
            for await batch in batches { await self?.apply(batch) }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Updates the index for one batch of FSEvents and reports what changed.
    func apply(_ events: [FolderWatcher.Event]) {
        assertNotOnMainThread()
        var changedNotes = Set<String>()
        var needsRescan = false
        for event in events {
            if event.requiresFullRescan {
                needsRescan = true
                continue
            }
            guard let path = relativePath(ofAbsolute: event.path), !Self.isHidden(path) else { continue }
            if event.changesFolders {
                needsRescan = true
            } else if !event.isDirectory, path.lowercased().hasSuffix(".md") {
                changedNotes.insert(path)
            }
        }

        if needsRescan {
            guard FileManager.default.fileExists(atPath: root.path), (try? scan()) != nil else {
                changesContinuation.yield(.libraryMissing)
                return
            }
        } else if !changedNotes.isEmpty {
            changedNotes.forEach(refreshSummary)
            publishIndex()
        }
        if needsRescan || !changedNotes.isEmpty {
            changesContinuation.yield(.notesChanged(changedNotes))
        }
    }

    func refreshSummary(for path: String) {
        let fileURL = url(for: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        if let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true {
            index.update(LibraryScanner.readSummary(at: fileURL, path: path, modified: values.contentModificationDate))
        } else {
            index.remove(path)
        }
    }

    // MARK: - Paths

    /// The real path, as FSEvents reports it. `URL.resolvingSymlinksInPath()` is no
    /// good here: it turns `/private/var/…` into `/var/…`, so events wouldn't match.
    private static func canonicalURL(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func url(for path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    private func relativePath(ofAbsolute absolute: String) -> String? {
        let prefix = root.path + "/"
        return absolute.hasPrefix(prefix) ? String(absolute.dropFirst(prefix.count)) : nil
    }

    /// Anything inside a dot-folder (.git, .obsidian) or a dotfile.
    /// Inside a hidden folder or an attachments folder: not part of the library's notes.
    private static func isHidden(_ path: String) -> Bool {
        path.split(separator: "/").contains {
            $0.hasPrefix(".") || $0.caseInsensitiveCompare(attachmentsFolderName) == .orderedSame
        }
    }
}

/// Debug guard for the "no file I/O on the main thread" rule.
func assertNotOnMainThread() {
    #if DEBUG
    dispatchPrecondition(condition: .notOnQueue(.main))
    #endif
}
