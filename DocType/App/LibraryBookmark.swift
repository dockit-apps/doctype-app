// Remembers which library folder the user chose, across launches.
// Stored as bookmark data rather than a path, so it survives moving or renaming the folder.

import Foundation

enum LibraryBookmark {
    private static let key = "libraryBookmark"

    static func save(_ url: URL) {
        guard let data = try? url.bookmarkData() else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale { save(url) }
        return url
    }
}
