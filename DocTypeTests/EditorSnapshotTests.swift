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

        Breadth-first search visits nodes **level by level**, *not* depth first. It's ~~slow~~ fast and uses a `queue`.
        Read [the lecture notes](https://example.com/bfs) before Friday.

        ## Steps with `bfs()`

        - Start at the source
        - Visit its neighbors
          - nested detail
        1. Mark visited
        2. Repeat

        - [ ] Review chapter 4
        - [x] Finish exercise sheet

        | Algorithm | Time |
        |-----------|------|
        | BFS       | O(V+E) |

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

        > Remember: BFS finds shortest paths
        > in unweighted graphs.

        ---

        ```python
        def bfs(graph, start):
            seen = {start}  # visited set
            return seen
        ```

        One more paragraph after the code.
        """

    /// Where the cursor is when rendering: it decides which markdown syntax shows.
    static let cursors: [String: String] = [
        "end": "after the code.",       // nothing revealed
        "heading": "Lecture 4",          // the heading's "#" shows
        "code": "let start",             // the Swift block's fences show
        "inline": "depth first",         // the first paragraph line's ** * ~~ ` show
    ]

    @Test(arguments: ["light-end", "dark-end", "light-heading", "light-code", "light-inline"])
    func renderSampleNote(variant: String) async throws {
        let parts = variant.split(separator: "-").map(String.init)
        let (appearance, cursor) = (parts[0], parts[1])
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.sample.write(to: folder.appending(path: "Sample.md"), atomically: true, encoding: .utf8)

        let editor = EditorController()
        editor.library = Library(root: folder)
        #expect(await editor.open("Sample.md"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 1240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.contentView = editor.scrollView
        let anchor = (editor.textView.string as NSString).range(of: Self.cursors[cursor]!)
        editor.textView.setSelectedRange(NSRange(location: anchor.upperBound, length: 0))
        if let layout = editor.textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }
        window.displayIfNeeded()

        let view = editor.scrollView
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: snapshotDirectory!).appending(path: "editor-\(variant).png"))
    }

    /// The situation from the bug report: three quote lines, then Return.
    @Test func renderQuoteAfterReturn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "> test\n> test\n> test".write(to: folder.appending(path: "Quote.md"), atomically: true, encoding: .utf8)

        let editor = EditorController()
        editor.library = Library(root: folder)
        #expect(await editor.open("Quote.md"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        editor.textView.setSelectedRange(NSRange(location: (editor.textView.string as NSString).length, length: 0))
        editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.textView.insertText("new line", replacementRange: editor.textView.selectedRange())
        if let layout = editor.textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        window.displayIfNeeded()

        let view = editor.scrollView
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: snapshotDirectory!).appending(path: "quote-after-return.png"))
    }

    static let tables = """
        Some text above the table, with a needle to find.

        | Name | Notes | C |
        | --- | --- | --- |
        | Alpha | **bold** | x |
        | Beta | a needle in a cell | y |
        | Gamma | ok | z |

        | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | alpha | beta | gamma | delta | epsilon | zeta | eta | theta | iota | kappa | lambda | mu |

        Text after.
        """

    /// Tables in a wide window: a twelve-column one fits the text column, a
    /// selection through a table, a cell being edited with its `**` shown,
    /// and Find's highlights.
    @Test(arguments: ["wide", "selection", "editing", "find"])
    func renderTables(variant: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DocTypeSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.tables.write(to: folder.appending(path: "Tables.md"), atomically: true, encoding: .utf8)

        let editor = EditorController()
        editor.library = Library(root: folder)
        #expect(await editor.open("Tables.md"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        window.makeFirstResponder(editor.textView)
        let text = editor.textView.string as NSString
        let layOut = { if let layout = editor.textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) } }
        layOut()
        switch variant {
        case "selection":
            let start = text.range(of: "text above").location
            editor.textView.setSelectedRange(NSRange(location: start, length: text.range(of: "| Beta").location + 4 - start))
        case "editing":
            let bold = text.range(of: "**bold**")
            editor.textView.setSelectedRange(NSRange(location: bold.location + 3, length: 0))
            try await Task.sleep(for: .milliseconds(50))  // the cell opens after the selection change
        case "find":
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setString("needle", forType: .string)
            editor.performFind(.showFindInterface)
            editor.performFind(.setSearchString)
            editor.performFind(.nextMatch)
            editor.performFind(.nextMatch)
        default:
            break
        }
        layOut()
        window.displayIfNeeded()

        let view = editor.scrollView
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: snapshotDirectory!).appending(path: "tables-\(variant).png"))
    }
}

