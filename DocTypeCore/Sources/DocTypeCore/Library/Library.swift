// The library on disk: owns all file I/O and the in-memory index.
// It is an actor, so every file operation runs off the main thread, and the app
// and a future MCP server can share the same API.

import Foundation
import os

public actor Library {
    public nonisolated let root: URL
    /// Publishes a new index snapshot after every change. One consumer per Library.
    public nonisolated let updates: AsyncStream<LibraryIndex>

    public private(set) var index = LibraryIndex()
    private let continuation: AsyncStream<LibraryIndex>.Continuation

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit { continuation.finish() }

    /// Reads the whole library folder and replaces the index.
    public func scan() throws {
        assertNotOnMainThread()
        let state = DocTypeCore.signposter.beginInterval("Library scan")
        defer { DocTypeCore.signposter.endInterval("Library scan", state) }

        let result = try LibraryScanner.scan(root: root)
        index = LibraryIndex(notes: result.notes, folders: result.folders)
        continuation.yield(index)
    }
}

/// Debug guard for the "no file I/O on the main thread" rule.
func assertNotOnMainThread() {
    #if DEBUG
    dispatchPrecondition(condition: .notOnQueue(.main))
    #endif
}
