// A note file's text, whatever its encoding. Notes are UTF-8 (that's what
// DocType writes), but a library may hold older files in another encoding:
// those still show up, can be read and searched, and open read-only, since
// saving them as UTF-8 would change bytes other programs rely on.
// Alternative considered: refusing to open them (what DocType did before);
// a note you can't read at all is worse than one you can't edit.

import Foundation

public struct NoteText: Equatable, Sendable {
    public let text: String
    /// False when the file isn't UTF-8: the editor shows it read-only.
    public let isUTF8: Bool

    public init(text: String, isUTF8: Bool) {
        self.text = text
        self.isUTF8 = isUTF8
    }

    /// UTF-8 when the bytes are valid UTF-8; UTF-16 when they start with its
    /// byte-order mark; otherwise Windows-1252 (Latin-1 for the few bytes it
    /// doesn't define), which reads any bytes.
    public static func decode(_ data: Data) -> NoteText {
        if let text = String(data: data, encoding: .utf8) { return NoteText(text: text, isUTF8: true) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return NoteText(text: text, isUTF8: false)
        }
        let text = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data.map { UInt16($0) }, as: UTF16.self)
        return NoteText(text: text, isUTF8: false)
    }
}
