// In-memory snapshot of a library: all note summaries plus the notebook tree.
// A plain value type, so the UI can hold a copy while the Library actor builds the next one.

import Foundation

public struct LibraryIndex: Sendable {
    /// What the note list shows: everything, one notebook (with subfolders), or one tag.
    public enum Filter: Hashable, Sendable {
        case all
        case notebook(String)
        case tag(String)
    }

    public private(set) var notes: [String: NoteSummary] = [:]
    public private(set) var notebooks: [Notebook] = []

    public init() {}

    public init(notes: [NoteSummary], folders: [String]) {
        self.notes = Dictionary(notes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        self.notebooks = Notebook.tree(from: folders)
    }

    /// Inserts or replaces one note's summary.
    mutating func update(_ note: NoteSummary) {
        notes[note.path] = note
    }

    /// Removes a note's summary (e.g. the file was deleted outside the app).
    mutating func remove(_ path: String) {
        notes[path] = nil
    }

    /// Every tag in the library with how many notes have it, sorted by name.
    /// Tags differing only in case count as one, shown in their most used spelling.
    public func tagCounts() -> [TagCount] {
        var spellings: [String: [String: Int]] = [:]  // lowercased → spelling → notes
        for note in notes.values {
            for tag in Set(note.tags) {
                spellings[tag.lowercased(), default: [:]][tag, default: 0] += 1
            }
        }
        return spellings.values.map { variants in
            let name = variants.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }!.key
            return TagCount(name: name, count: variants.values.reduce(0, +))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Notes matching `filter`, most recently modified first.
    public func notes(matching filter: Filter) -> [NoteSummary] {
        notes.values
            .filter { $0.matches(filter) }
            .sorted(by: NoteSummary.newestFirst)
    }
}

public struct TagCount: Hashable, Sendable {
    public let name: String
    public let count: Int
}

public struct Notebook: Identifiable, Hashable, Sendable {
    /// Folder path relative to the library root, e.g. `University/Algorithms`.
    public let path: String
    public var name: String { (path as NSString).lastPathComponent }
    /// `nil` for leaf notebooks, which is what SwiftUI's `OutlineGroup` expects.
    public let children: [Notebook]?

    public var id: String { path }

    /// Builds a sorted tree from flat folder paths (`A`, `A/B`, `C`).
    static func tree(from folders: [String]) -> [Notebook] {
        let childrenByParent = Dictionary(grouping: folders) { ($0 as NSString).deletingLastPathComponent }
        func build(parent: String) -> [Notebook] {
            (childrenByParent[parent] ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { path in
                    let children = build(parent: path)
                    return Notebook(path: path, children: children.isEmpty ? nil : children)
                }
        }
        return build(parent: "")
    }
}

extension NoteSummary {
    func matches(_ filter: LibraryIndex.Filter) -> Bool {
        switch filter {
        case .all:
            true
        case .notebook(let folder):
            notebook == folder || notebook.hasPrefix(folder + "/")
        case .tag(let tag):
            tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }
}
