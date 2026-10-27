// Watches a folder tree with FSEvents and reports batches of changed paths.
//
// FSEvents sees changes from any process (git, vim, Finder, a future MCP server).
// NSFilePresenter would only see writes made through NSFileCoordinator, which
// git and most editors don't use.

import CoreServices
import Foundation

/// `@unchecked Sendable`: the FSEvents stream is only touched in `start()`/`stop()`,
/// and FSEvents itself delivers callbacks on our private serial queue.
public final class FolderWatcher: @unchecked Sendable {
    public struct Event: Sendable {
        /// Absolute path, with symlinks resolved (e.g. `/private/var/...`).
        public let path: String
        public let flags: FSEventStreamEventFlags

        public var isDirectory: Bool { has(kFSEventStreamEventFlagItemIsDir) }
        /// The directory structure changed (folder created, removed or renamed).
        public var changesFolders: Bool {
            isDirectory && (has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved)
                || has(kFSEventStreamEventFlagItemRenamed))
        }
        /// FSEvents lost track of details (or the root moved): rescan everything.
        public var requiresFullRescan: Bool {
            has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagRootChanged)
                || has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped)
        }

        private func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
    }

    private let root: URL
    private let latency: TimeInterval
    private let handler: @Sendable ([Event]) -> Void
    private let queue = DispatchQueue(label: "io.github.dockit-apps.doctype.folder-watcher")
    private var stream: FSEventStreamRef?

    /// - Parameter latency: FSEvents groups changes within this window into one batch,
    ///   so a `git checkout` of 200 files arrives as a few batches, not 200 callbacks.
    public init(root: URL, latency: TimeInterval = 0.3, handler: @escaping @Sendable ([Event]) -> Void) {
        self.root = root
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = kFSEventStreamCreateFlagFileEvents   // one event per file, not per folder
            | kFSEventStreamCreateFlagNoDefer             // deliver the first change right away
            | kFSEventStreamCreateFlagIgnoreSelf          // our own saves aren't "external" changes
            | kFSEventStreamCreateFlagWatchRoot           // tell us if the library folder moves
            | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let pathList = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        let events = (0..<min(count, pathList.count)).map { Event(path: pathList[$0], flags: flags[$0]) }
        watcher.handler(events)
    }
}
