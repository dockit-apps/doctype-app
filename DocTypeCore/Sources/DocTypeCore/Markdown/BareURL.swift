// Finds URLs written without link syntax, following GitHub's "extended autolink"
// rules closely enough for notes:
// - starts with "https://", "http://" or "www." at the start of the text or after
//   a space or one of `*_~(`;
// - runs until a space or "<";
// - trailing punctuation that usually ends the sentence (`.,:;!?*_~'"`) is not
//   part of it, and neither is a ")" without a matching "(" in the URL.
// So "see https://swift.org." links "https://swift.org", and
// "(https://en.wikipedia.org/wiki/Graph_(math))" keeps the inner parentheses.

import Foundation

enum BareURL {
    private static let candidate = try! NSRegularExpression(
        pattern: #"(?<![^\s*_~(])(?:https?://|www\.)[^\s<]+"#, options: [.caseInsensitive])

    static func matches(in text: NSString, range: NSRange) -> [NSRange] {
        candidate.matches(in: text as String, range: range).compactMap { match in
            var end = match.range.upperBound
            let start = match.range.location
            while end > start {
                let last = text.character(at: end - 1)
                if let scalar = Unicode.Scalar(last), ".,:;!?*_~'\"".unicodeScalars.contains(scalar) {
                    end -= 1
                } else if last == 41 /* ) */, !hasMatchingOpen(text, start: start, end: end) {
                    end -= 1
                } else {
                    break
                }
            }
            // A scheme or "www." alone isn't a URL.
            let url = text.substring(with: NSRange(location: start, length: end - start))
            guard url.contains("."), !["http://", "https://", "www."].contains(url.lowercased()) else { return nil }
            return NSRange(location: start, length: end - start)
        }
    }

    /// True if the ")" at `end - 1` closes a "(" inside the URL.
    private static func hasMatchingOpen(_ text: NSString, start: Int, end: Int) -> Bool {
        var depth = 0
        for index in start..<end {
            switch text.character(at: index) {
            case 40: depth += 1
            case 41: depth -= 1
            default: break
            }
        }
        return depth >= 0
    }
}
