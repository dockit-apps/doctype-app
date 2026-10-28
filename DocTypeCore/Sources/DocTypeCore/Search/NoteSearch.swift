// Full-text search over the notes in an index snapshot (title, frontmatter and body).
//
// Matching: the query is split into words, and a note matches when it contains
// every word, anywhere ("graph bfs" finds a note with both). Case, accents and
// full/half width are ignored, so "ozet" finds "Özet", like Finder's search.
// Turkish dotless "ı" also matches "i" (it isn't an accented i, so folding alone
// keeps it apart), so "notlari" finds "notları" whatever the keyboard.
// Words match inside other words ("graph" finds "Graphs"), which is what people
// expect while typing.
//
// Ranking: notes whose title contains every word come first, then the rest;
// each group newest first, the same order as the unfiltered list. A title hit is
// almost always the note you're looking for, and recency is the order notes are
// already shown in, so results don't jump around while you type.
// Alternatives considered: relevance scoring (counting hits, TF-IDF) ranks long
// notes with repeated words above the short note you meant, and makes the order
// hard to predict; fuzzy matching (like the palette) finds too much in long bodies.
//
// Speed: every note's text is folded (lowercased, accents removed) once when it is
// indexed, so a search is just a byte search (memmem) per word per note. That
// keeps a search over a 1,000-note library in the low milliseconds.

import Foundation

public struct NoteSearch: Sendable {
    /// The query's words, folded like the indexed text.
    let words: [String]

    public init(_ query: String) {
        words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// True when the query has no words (only spaces), so there's nothing to search for.
    public var isEmpty: Bool { words.isEmpty }

    /// Notes shown by `filter` that contain every word: title hits first, then the
    /// rest, each newest first.
    public func results(in index: LibraryIndex, filter: LibraryIndex.Filter) -> [NoteSummary] {
        let state = DocTypeCore.signposter.beginInterval("Search")
        defer { DocTypeCore.signposter.endInterval("Search", state) }

        var titleHits: [NoteSummary] = []
        var otherHits: [NoteSummary] = []
        for note in index.notes.values where note.matches(filter) {
            guard words.allSatisfy({ Self.contains(note.searchText, $0) }) else { continue }
            if words.allSatisfy({ Self.contains(note.searchTitle, $0) }) {
                titleHits.append(note)
            } else {
                otherHits.append(note)
            }
        }
        return titleHits.sorted(by: NoteSummary.newestFirst) + otherHits.sorted(by: NoteSummary.newestFirst)
    }

    /// Text as search compares it: no case, accents or width differences.
    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // Checking first is much cheaper than always replacing (most notes have no "ı").
        return folded.unicodeScalars.contains("ı") ? folded.replacingOccurrences(of: "ı", with: "i") : folded
    }

    /// Byte search in UTF-8. Both sides are folded the same way, and UTF-8 never
    /// matches in the middle of a character, so this equals a character search.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        var haystack = haystack, needle = needle  // withUTF8 needs `var`; no copy is made
        return haystack.withUTF8 { text in
            needle.withUTF8 { word in
                guard let textStart = text.baseAddress, let wordStart = word.baseAddress else { return word.isEmpty }
                return memmem(textStart, text.count, wordStart, word.count) != nil
            }
        }
    }
}
