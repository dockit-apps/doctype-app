#!/usr/bin/env swift
// Generates a fake library for performance checks:
// 1,000 notes across nested notebooks (frontmatter tags, headings, code, tasks),
// plus one 5,000-line note at Big/5000-lines.md.
//
// Usage: swift Scripts/make-fixtures.swift <output-folder> [note-count]
// Output is deterministic (seeded), so measurements are comparable between runs.

import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift Scripts/make-fixtures.swift <output-folder> [note-count]")
    exit(1)
}
let root = URL(fileURLWithPath: arguments[1])
let noteCount = arguments.count >= 3 ? Int(arguments[2]) ?? 1_000 : 1_000

/// Small deterministic random generator (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
var random = SeededRandom(state: 42)

let notebooks = [
    "University/Algorithms", "University/Operating Systems", "University/Linear Algebra",
    "University/Databases", "University/Computer Networks", "University/Compilers",
    "Engineering/Swift", "Engineering/Backend", "Engineering/DevOps", "Engineering/Architecture",
    "Engineering/Swift/Concurrency", "Personal/Journal", "Personal/Shopping", "Personal/Travel",
    "Personal/Books", "Projects/DocType", "Projects/DocShelf", "Inbox", "Archive/2024", "Archive/2025",
]
let tags = ["exam", "lecture", "todo", "swift", "idea", "reading", "week-1", "week-2", "reference", "draft"]
let words = """
    graph vertex edge queue stack heap process thread scheduler memory page cache matrix vector
    eigenvalue index query transaction packet router protocol parser token grammar actor task
    async await closure protocol struct enum module package build deploy server client request
    response latency budget morning coffee walk book chapter idea plan list milk eggs bread
    """.split(whereSeparator: \.isWhitespace).map(String.init)

func sentence(_ length: Int) -> String {
    let body = (0..<length).map { _ in words.randomElement(using: &random)! }.joined(separator: " ")
    return body.prefix(1).uppercased() + body.dropFirst() + "."
}

func paragraph() -> String {
    (0..<Int.random(in: 2...5, using: &random)).map { _ in sentence(Int.random(in: 6...14, using: &random)) }
        .joined(separator: " ")
}

func noteBody(title: String, sections: Int) -> String {
    var lines: [String] = []
    let noteTags = tags.shuffled(using: &random).prefix(Int.random(in: 0...3, using: &random))
    if !noteTags.isEmpty {
        lines += ["---", "tags: [\(noteTags.joined(separator: ", "))]", "---", ""]
    }
    lines += ["# \(title)", ""]
    for section in 1...sections {
        lines += ["## Section \(section)", "", paragraph(), ""]
        switch Int.random(in: 0..<4, using: &random) {
        case 0:
            lines += ["```swift", "func step\(section)(_ input: [Int]) -> Int {",
                      "    input.reduce(0, +)", "}", "```", ""]
        case 1:
            for _ in 0..<Int.random(in: 2...6, using: &random) {
                lines.append("- [\(Bool.random(using: &random) ? "x" : " ")] \(sentence(4))")
            }
            lines.append("")
        case 2:
            lines += ["- **Key point:** \(sentence(6))", "- *Note:* `\(words.randomElement(using: &random)!)`",
                      "- See [docs](https://example.com/\(section))", ""]
        default:
            lines += ["> \(sentence(10))", ""]
        }
    }
    return lines.joined(separator: "\n")
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: root)
for notebook in notebooks {
    try fileManager.createDirectory(at: root.appending(path: notebook), withIntermediateDirectories: true)
}

let now = Date()
for number in 1...noteCount {
    let notebook = notebooks[number % notebooks.count]
    let title = "Note \(number) \(words.randomElement(using: &random)!)"
    let url = root.appending(path: notebook).appending(path: "\(title).md")
    try noteBody(title: title, sections: Int.random(in: 1...6, using: &random))
        .write(to: url, atomically: true, encoding: .utf8)
    let age = TimeInterval(Int.random(in: 0...(365 * 24 * 3600), using: &random))
    try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
}

// One very long note for the "typing stays smooth in a 5,000-line note" budget.
let big = root.appending(path: "Big")
try fileManager.createDirectory(at: big, withIntermediateDirectories: true)
var bigLines: [String] = []
var section = 0
while bigLines.count < 5_000 {
    section += 1
    bigLines += noteBody(title: "Part \(section)", sections: 3).components(separatedBy: "\n")
}
try bigLines.prefix(5_000).joined(separator: "\n").write(to: big.appending(path: "5000-lines.md"), atomically: true, encoding: .utf8)

print("Wrote \(noteCount) notes + Big/5000-lines.md to \(root.path)")
