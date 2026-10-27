// Renders the editor offscreen to PNG files, to look at styling without running the app.
// Opt-in: set DOCTYPE_SNAPSHOT_DIR, e.g.
//   TEST_RUNNER_DOCTYPE_SNAPSHOT_DIR=/tmp/shots xcodebuild test -project DocType.xcodeproj -scheme DocType

import AppKit
import DocTypeCore
import Foundation
import Testing
@testable import DocType

nonisolated private let snapshotDirectory = ProcessInfo.processInfo.environment["DOCTYPE_SNAPSHOT_DIR"]

@MainActor
@Suite(.enabled(if: snapshotDirectory != nil, "Set DOCTYPE_SNAPSHOT_DIR to render snapshots"))
struct EditorSnapshotTests {
    static let sample = """
        # Lecture 4: Graphs

        Breadth-first search visits nodes **level by level**.

        ```swift
        struct Graph {
            let edges: [Int: [Int]]  // adjacency list

            func neighbors(of node: Int) -> [Int] {
                edges[node, default: []]
            }
        }
        let start = 42
        print("Visiting \\(start)")
        ```

        > Remember: BFS finds shortest paths in unweighted graphs.

        ```python
        def bfs(graph, start):
            seen = {start}  # visited set
            return seen
        ```

        One more paragraph after the code.
        """

    @Test(arguments: ["light", "dark"])
    func renderSampleNote(appearance: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.sample.write(to: folder.appending(path: "Sample.md"), atomically: true, encoding: .utf8)

        let editor = EditorController()
        editor.library = Library(root: folder)
        #expect(await editor.open("Sample.md"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.contentView = editor.scrollView
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let layout = editor.textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }
        window.displayIfNeeded()

        let view = editor.scrollView
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: snapshotDirectory!).appending(path: "editor-\(appearance).png")
        try png.write(to: output)
    }
}
