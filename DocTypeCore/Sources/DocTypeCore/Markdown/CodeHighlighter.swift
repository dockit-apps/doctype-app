// Syntax highlighting for fenced code blocks in the editor.
//
// A small tokenizer driven by a per-language table (keywords, comment and string
// syntax) instead of a full grammar: it's fast enough to re-run on every
// keystroke, needs no dependency, and adding a language is one table entry.
// It's approximate by design (no semantic analysis); the preview uses
// highlight.js for the exact rendering.

import Foundation

public enum CodeHighlighter {
    /// Token spans for the code in `range` of `text`, or none for an unknown language.
    public static func spans(in text: NSString, range: NSRange, language: String) -> [StyleSpan] {
        guard let definition = LanguageDefinition.named(language) else { return [] }
        var tokenizer = Tokenizer(text: text, range: range, language: definition)
        return tokenizer.tokens()
    }
}

/// How one language looks to the tokenizer.
struct LanguageDefinition {
    var keywords: Set<String>
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)? = nil
    /// String delimiters, longest first (`"""` before `"`).
    var stringDelimiters: [String] = ["\"", "'"]
    /// Capitalized identifiers are types (Swift, Java, …), not in Python or shell.
    var capitalizedAreTypes = true
    var caseInsensitiveKeywords = false

    static func named(_ info: String) -> LanguageDefinition? {
        let name = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return aliases[name].flatMap { definitions[$0] }
    }

    private static let aliases: [String: String] = [
        "swift": "swift", "python": "python", "py": "python", "javascript": "javascript", "js": "javascript",
        "jsx": "javascript", "typescript": "typescript", "ts": "typescript", "tsx": "typescript",
        "java": "java", "kotlin": "kotlin", "kt": "kotlin", "c": "c", "h": "c", "cpp": "cpp", "c++": "cpp",
        "cc": "cpp", "hpp": "cpp", "csharp": "csharp", "cs": "csharp", "c#": "csharp", "go": "go",
        "golang": "go", "rust": "rust", "rs": "rust", "bash": "shell", "sh": "shell", "shell": "shell",
        "zsh": "shell", "console": "shell", "sql": "sql", "json": "json", "yaml": "yaml", "yml": "yaml",
        "haskell": "haskell", "hs": "haskell", "ruby": "ruby", "rb": "ruby",
    ]

    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    private static let cFamilyComments = (line: ["//"], block: ("/*", "*/"))
    private static let cKeywords = """
        auto break case char const continue default do double else enum extern float for goto if inline int \
        long register return short signed sizeof static struct switch typedef union unsigned void volatile while \
        bool true false NULL
        """

    private static let definitions: [String: LanguageDefinition] = [
        "swift": LanguageDefinition(keywords: words("""
            associatedtype actor async await break case catch class continue default defer deinit do else enum \
            extension fallthrough false fileprivate final for func guard if import in init inout internal is \
            let mutating nil nonisolated open operator override private protocol public repeat rethrows return \
            self Self some static struct subscript super switch throw throws true try typealias var weak where while any
            """), lineComments: cFamilyComments.line, blockComment: cFamilyComments.block,
            stringDelimiters: ["\"\"\"", "\""]),
        "python": LanguageDefinition(keywords: words("""
            False None True and as assert async await break class continue def del elif else except finally for \
            from global if import in is lambda nonlocal not or pass raise return try while with yield self match case
            """), lineComments: ["#"], stringDelimiters: ["\"\"\"", "'''", "\"", "'"], capitalizedAreTypes: false),
        "javascript": LanguageDefinition(keywords: words(javaScriptKeywords),
            lineComments: cFamilyComments.line, blockComment: cFamilyComments.block, stringDelimiters: ["`", "\"", "'"]),
        "typescript": LanguageDefinition(keywords: words(javaScriptKeywords + """
             interface type enum implements declare readonly abstract namespace keyof as any unknown never \
            string number boolean private public protected
            """), lineComments: cFamilyComments.line, blockComment: cFamilyComments.block, stringDelimiters: ["`", "\"", "'"]),
        "java": LanguageDefinition(keywords: words("""
            abstract assert boolean break byte case catch char class const continue default do double else enum \
            extends final finally float for if implements import instanceof int interface long native new package \
            private protected public return short static super switch synchronized this throw throws try void \
            volatile while true false null var record
            """), lineComments: cFamilyComments.line, blockComment: cFamilyComments.block),
        "kotlin": LanguageDefinition(keywords: words("""
            as break class continue do else false for fun if in interface is null object package return super this \
            throw true try typealias val var when while by catch constructor data enum finally get import init \
            internal open override private protected public sealed set suspend companion lateinit
            """), lineComments: cFamilyComments.line, blockComment: cFamilyComments.block, stringDelimiters: ["\"\"\"", "\"", "'"]),
        "c": LanguageDefinition(keywords: words(cKeywords + " #include #define #ifdef #ifndef #endif #if #else"),
            lineComments: cFamilyComments.line, blockComment: cFamilyComments.block),
        "cpp": LanguageDefinition(keywords: words(cKeywords + """
             class namespace template typename public private protected virtual override new delete this using \
            nullptr const_cast static_cast dynamic_cast try catch throw constexpr noexcept operator friend \
            #include #define #ifdef #ifndef #endif #if #else std
            """), lineComments: cFamilyComments.line, blockComment: cFamilyComments.block),
        "csharp": LanguageDefinition(keywords: words("""
            abstract as async await base bool break byte case catch char class const continue decimal default \
            delegate do double else enum event false finally float for foreach if in int interface internal is \
            lock long namespace new null object out override params private protected public readonly ref \
            return sealed short static string struct switch this throw true try typeof uint using var virtual void while
            """), lineComments: cFamilyComments.line, blockComment: cFamilyComments.block),
        "go": LanguageDefinition(keywords: words("""
            break case chan const continue default defer else fallthrough for func go goto if import interface \
            map package range return select struct switch type var true false nil
            """), lineComments: cFamilyComments.line, blockComment: cFamilyComments.block, stringDelimiters: ["`", "\"", "'"],
            capitalizedAreTypes: false),
        "rust": LanguageDefinition(keywords: words("""
            as async await break const continue crate dyn else enum extern false fn for if impl in let loop match \
            mod move mut pub ref return self Self static struct super trait true type unsafe use where while
            """), lineComments: cFamilyComments.line, blockComment: cFamilyComments.block, stringDelimiters: ["\""]),
        "shell": LanguageDefinition(keywords: words("""
            if then else elif fi for while until do done case esac in function return export local readonly \
            echo cd source exit set unset
            """), lineComments: ["#"], capitalizedAreTypes: false),
        "sql": LanguageDefinition(keywords: words("""
            select from where insert into values update set delete create table drop alter add primary key \
            foreign references join inner left right outer on group by order having limit offset as and or \
            not null is in exists distinct union all index view begin commit rollback default unique check
            """), lineComments: ["--"], blockComment: cFamilyComments.block, stringDelimiters: ["'"],
            capitalizedAreTypes: false, caseInsensitiveKeywords: true),
        "json": LanguageDefinition(keywords: words("true false null"), stringDelimiters: ["\""], capitalizedAreTypes: false),
        "yaml": LanguageDefinition(keywords: words("true false null yes no"), lineComments: ["#"], capitalizedAreTypes: false),
        "haskell": LanguageDefinition(keywords: words("""
            case class data default deriving do else if import in infix infixl infixr instance let module \
            newtype of then type where
            """), lineComments: ["--"], blockComment: ("{-", "-}"), stringDelimiters: ["\""]),
        "ruby": LanguageDefinition(keywords: words("""
            alias and begin break case class def defined? do else elsif end ensure false for if in module next \
            nil not or redo rescue retry return self super then true undef unless until when while yield require
            """), lineComments: ["#"]),
    ]

    private static let javaScriptKeywords = """
        async await break case catch class const continue debugger default delete do else export extends \
        false finally for from function if import in instanceof let new null of return static super switch \
        this throw true try typeof undefined var void while with yield
        """
}

/// One pass over the code, emitting spans. Strings and block comments may span lines.
///
/// Reads the code into a UTF-16 buffer once and compares characters directly:
/// creating substrings at every position made typing in a 1,000-line block
/// cost ~4.5 ms per keystroke.
private struct Tokenizer {
    private let characters: [unichar]
    /// Where `characters[0]` sits in the document.
    private let base: Int
    private let language: LanguageDefinition
    private let lineComments: [[unichar]]
    private let blockComment: (open: [unichar], close: [unichar])?
    private let stringDelimiters: [[unichar]]
    /// Keywords as UTF-16, so a word can be looked up as a slice without building a String.
    private let keywords: Set<ArraySlice<unichar>>
    private var spans: [StyleSpan] = []

    init(text: NSString, range: NSRange, language: LanguageDefinition) {
        var buffer = [unichar](repeating: 0, count: range.length)
        text.getCharacters(&buffer, range: range)
        characters = buffer
        base = range.location
        self.language = language
        lineComments = language.lineComments.map { Array($0.utf16) }
        blockComment = language.blockComment.map { (Array($0.open.utf16), Array($0.close.utf16)) }
        stringDelimiters = language.stringDelimiters.map { Array($0.utf16) }
        keywords = Set(language.keywords.map { ArraySlice($0.utf16) })
    }

    mutating func tokens() -> [StyleSpan] {
        var position = 0
        while position < characters.count {
            position = next(at: position)
        }
        return spans
    }

    /// Handles the token starting at `position` and returns where the next one starts.
    private mutating func next(at position: Int) -> Int {
        if let block = blockComment, matches(block.open, at: position) {
            let close = find(block.close, from: position + block.open.count)
            return emit(.comment, from: position, to: close.map { $0 + block.close.count } ?? characters.count)
        }
        for marker in lineComments where matches(marker, at: position) {
            return emit(.comment, from: position, to: lineEnd(from: position))
        }
        for delimiter in stringDelimiters where matches(delimiter, at: position) {
            return emit(.string, from: position, to: stringEnd(from: position + delimiter.count, delimiter: delimiter))
        }
        let character = characters[position]
        if isDigit(character), position == 0 || !isIdentifier(characters[position - 1]) {
            var stop = position + 1
            while stop < characters.count, isIdentifier(characters[stop]) || characters[stop] == 46 { stop += 1 }  // 46 = "."
            return emit(.number, from: position, to: stop)
        }
        if isIdentifierStart(character) {
            var stop = position + 1
            while stop < characters.count, isIdentifier(characters[stop]) { stop += 1 }
            if isKeyword(characters[position..<stop]) {
                _ = emit(.keyword, from: position, to: stop)
            } else if language.capitalizedAreTypes, character >= 65, character <= 90 {  // starts with A–Z
                _ = emit(.type, from: position, to: stop)
            }
            return stop
        }
        return position + 1
    }

    private func isKeyword(_ word: ArraySlice<unichar>) -> Bool {
        guard language.caseInsensitiveKeywords else { return keywords.contains(word) }
        // Lowercase ASCII letters for SQL-style keywords.
        return keywords.contains(ArraySlice(word.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }))
    }

    private mutating func emit(_ token: CodeToken, from start: Int, to stop: Int) -> Int {
        let stop = min(stop, characters.count)
        if stop > start {
            spans.append(StyleSpan(NSRange(location: base + start, length: stop - start), .code(token)))
        }
        return max(stop, start + 1)
    }

    /// After the closing delimiter. Single-character quotes end at the line end;
    /// backslash escapes are skipped.
    private func stringEnd(from start: Int, delimiter: [unichar]) -> Int {
        let multiLine = delimiter.count == 3 || delimiter == [96]  // ``` / """ / ' ' ' or a backtick
        var position = start
        while position < characters.count {
            let character = characters[position]
            if character == 92 { position += 2; continue }  // backslash
            if !multiLine, character == 10 || character == 13 { return position }
            if matches(delimiter, at: position) { return position + delimiter.count }
            position += 1
        }
        return characters.count
    }

    private func lineEnd(from start: Int) -> Int {
        var position = start
        while position < characters.count, characters[position] != 10, characters[position] != 13 { position += 1 }
        return position
    }

    private func find(_ needle: [unichar], from start: Int) -> Int? {
        var position = start
        while position + needle.count <= characters.count {
            if matches(needle, at: position) { return position }
            position += 1
        }
        return nil
    }

    private func matches(_ needle: [unichar], at position: Int) -> Bool {
        guard position + needle.count <= characters.count else { return false }
        for offset in 0..<needle.count where characters[position + offset] != needle[offset] { return false }
        return true
    }

    private func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
    private func isIdentifierStart(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 35 || c > 127  // letters, _, # (C directives)
    }
    private func isIdentifier(_ c: unichar) -> Bool { isIdentifierStart(c) || isDigit(c) || c == 63 /* ? for Ruby */ }
}
