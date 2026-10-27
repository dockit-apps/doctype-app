// Creating, renaming, moving and trashing notes and notebooks.
// Our own file operations don't produce watcher events (FSEvents IgnoreSelf),
// so every operation updates the index itself.

import Foundation

public enum LibraryError: LocalizedError, Equatable {
    case invalidName(String)
    case nameTaken(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let reason): reason
        case .nameTaken(let name): "“\(name)” already exists in this notebook."
        case .notFound(let path): "“\(path)” no longer exists."
        }
    }
}

extension Library {
    // MARK: - Notes

    /// Creates an empty note in `folder` (`""` = library root), named `title`
    /// or `title 2`, `title 3`, … if taken. Returns the new note's path.
    public func createNote(in folder: String, title: String = "Untitled") throws -> String {
        let path = FileNaming.availablePath(name: title, extension: "md", in: folder, exists: exists)
        try save(path, text: "")
        return path
    }

    /// Renames a note's file. The title is the filename, so this is the "rename note" action.
    /// Returns the new path.
    public func renameNote(_ path: String, to title: String) throws -> String {
        let name = try FileNaming.validatedName(title)
        return try moveFile(path, to: join(parent(of: path), "\(name).md"))
    }

    /// Moves a note into another notebook (`""` = library root). Returns the new path.
    public func moveNote(_ path: String, toNotebook folder: String) throws -> String {
        try moveFile(path, to: join(folder, (path as NSString).lastPathComponent))
    }

    /// Moves a note to the system Trash, where Finder's "Put Back" can restore it.
    /// Returns where the file ended up in the Trash.
    @discardableResult
    public func trashNote(_ path: String) throws -> URL? {
        assertNotOnMainThread()
        guard exists(path) else { throw LibraryError.notFound(path) }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url(for: path), resultingItemURL: &trashedURL)
        index.remove(path)
        publishIndex()
        return trashedURL as URL?
    }

    // MARK: - Notebooks

    /// Creates a folder named `name` (or `name 2`, …) inside `parent`. Returns its path.
    public func createNotebook(in parent: String, name: String = "Untitled Notebook") throws -> String {
        assertNotOnMainThread()
        let path = FileNaming.availablePath(name: name, extension: nil, in: parent, exists: exists)
        try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        try scan()
        return path
    }

    /// Renames a notebook folder; every note inside (including subfolders) moves with it.
    /// Returns the new path.
    public func renameNotebook(_ path: String, to name: String) throws -> String {
        let newName = try FileNaming.validatedName(name)
        let newPath = try moveFile(path, to: join(parent(of: path), newName), isNote: false)
        try scan()
        return newPath
    }

    // MARK: - Helpers

    /// Moves a file or folder within the library. Refuses to overwrite, and handles
    /// case-only renames (`note` → `Note`), which APFS would otherwise see as "exists".
    @discardableResult
    private func moveFile(_ from: String, to destination: String, isNote: Bool = true) throws -> String {
        assertNotOnMainThread()
        guard from != destination else { return from }
        guard exists(from) else { throw LibraryError.notFound(from) }
        let isCaseOnlyChange = from.lowercased() == destination.lowercased()
        if !isCaseOnlyChange, exists(destination) {
            let name = (destination as NSString).lastPathComponent
            throw LibraryError.nameTaken(isNote ? (name as NSString).deletingPathExtension : name)
        }

        let fileManager = FileManager.default
        if isCaseOnlyChange {
            let temporary = join(parent(of: from), ".doctype-rename-\(UUID().uuidString)")
            try fileManager.moveItem(at: url(for: from), to: url(for: temporary))
            try fileManager.moveItem(at: url(for: temporary), to: url(for: destination))
        } else {
            try fileManager.createDirectory(at: url(for: parent(of: destination)), withIntermediateDirectories: true)
            try fileManager.moveItem(at: url(for: from), to: url(for: destination))
        }

        if isNote {
            index.remove(from)
            refreshSummary(for: destination)
            publishIndex()
        }
        return destination
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    private func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }
}
