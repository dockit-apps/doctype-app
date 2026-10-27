// Fuzzy matching for the command palette (and later pickers): "nn" finds "New Note".
//
// What it does
// - A candidate matches if the query's characters appear in it in order, ignoring
//   case and accents ("nn" → "New Note", "cafe" → "Café").
// - Scoring rewards what people type when they abbreviate:
//   - +15 for matching the very first character;
//   - +10 for each match at the start of a word, so initials like "nn" win;
//   - +8 for each match right after the previous one, so typing part of a word
//     ("side") beats scattered word starts ("Show Inbox Database");
//   - −1 for each skipped character between matches (at most −10 per gap).
// - Results are sorted by score, then shorter titles, then alphabetically.
// - Word-start matches are preferred when the query can still be completed that
//   way, so "nb" scores "Rename Notebook" on "N…b" rather than on "reName".
//
// Alternatives considered
// - Plain substring search: predictable, but "nn" or "tsb" (Toggle Sidebar) find nothing.
// - fzf/Smith-Waterman-style optimal alignment: finds the best-scoring match, but
//   it's much more code to read, for a list of a few dozen commands.
// - Prefix-only matching: misses "sidebar" → "Toggle Sidebar".

import Foundation

public enum FuzzyMatch {
    /// Score for `candidate`, or nil if `query` doesn't match. Higher is better.
    /// An empty query matches everything with score 0.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(normalize(query).filter { !$0.isWhitespace })
        let haystack = Array(normalize(candidate))
        guard !needle.isEmpty else { return 0 }
        guard let positions = matchPositions(of: needle, in: haystack, preferWordStarts: true)
                ?? matchPositions(of: needle, in: haystack, preferWordStarts: false) else { return nil }

        var score = 0
        var previous: Int?
        for position in positions {
            if position == 0 { score += 15 }
            if isWordStart(position, in: haystack) { score += 10 }
            if let previous {
                let gap = position - previous - 1
                score += gap == 0 ? 8 : -min(gap, 10)
            }
            previous = position
        }
        return score
    }

    /// Items matching `query`, best first. An empty query keeps the original order.
    public static func rank<Item>(_ items: [Item], by query: String, text: (Item) -> String) -> [Item] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items
            .compactMap { item in score(query, in: text(item)).map { (item, text(item), $0) } }
            .sorted { lhs, rhs in
                if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
                if lhs.1.count != rhs.1.count { return lhs.1.count < rhs.1.count }
                return lhs.1.localizedStandardCompare(rhs.1) == .orderedAscending
            }
            .map(\.0)
    }

    // MARK: - Helpers

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isWordStart(_ index: Int, in characters: [Character]) -> Bool {
        index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber)
    }

    /// Greedy left-to-right match. With `preferWordStarts`, each character first
    /// looks for an occurrence at a word start; nil if the query can't be completed.
    private static func matchPositions(
        of needle: [Character], in haystack: [Character], preferWordStarts: Bool
    ) -> [Int]? {
        var positions: [Int] = []
        var start = 0
        for character in needle {
            let range = start..<haystack.count
            let wordStart = preferWordStarts
                ? range.first { haystack[$0] == character && isWordStart($0, in: haystack) } : nil
            guard let found = wordStart ?? range.first(where: { haystack[$0] == character }) else { return nil }
            positions.append(found)
            start = found + 1
        }
        return positions
    }
}
