// Tests for the command registry, shortcut display and fuzzy matching.

import Testing
@testable import DocTypeCore

struct CommandRegistryTests {
    @Test func everyCommandHasATitle() {
        for command in CommandID.allCases {
            #expect(!command.title.isEmpty, "\(command) has no title")
        }
    }

    @Test func noTwoCommandsShareAShortcut() {
        var owners: [Shortcut: CommandID] = [:]
        for command in CommandID.allCases {
            for shortcut in command.info.defaultShortcuts {
                #expect(owners[shortcut] == nil,
                        "\(shortcut.displayString) used by both \(owners[shortcut]!) and \(command)")
                owners[shortcut] = command
            }
        }
    }

    @Test func identifiersAreUnique() {
        #expect(Set(CommandID.allCases.map(\.rawValue)).count == CommandID.allCases.count)
    }
}

struct ShortcutTests {
    @Test func displayStringUsesMacModifierOrder() {
        #expect(Shortcut.command("p", .shift).displayString == "⇧⌘P")
        #expect(Shortcut(.character("1"), [.command, .option]).displayString == "⌥⌘1")
        #expect(Shortcut(.delete, .command).displayString == "⌘⌫")
        #expect(Shortcut.command("s", .control).displayString == "⌃⌘S")
    }

    @Test func characterIsStoredLowercase() {
        #expect(Shortcut.command("P") == Shortcut.command("p"))
    }
}

struct FuzzyMatchTests {
    @Test func subsequenceMatchesAndOthersDont() {
        #expect(FuzzyMatch.score("nn", in: "New Note") != nil)
        #expect(FuzzyMatch.score("nx", in: "New Note") == nil)
        #expect(FuzzyMatch.score("eton", in: "New Note") == nil)  // order matters
    }

    @Test func ignoresCaseAccentsAndSpaces() {
        #expect(FuzzyMatch.score("CAFE", in: "Café") != nil)
        #expect(FuzzyMatch.score("new note", in: "New Note") != nil)
    }

    @Test func initialsBeatMidWordMatches() {
        let ranked = FuzzyMatch.rank(["Rename Notebook", "New Note"], by: "nn") { $0 }
        #expect(ranked == ["New Note", "Rename Notebook"])
    }

    @Test func contiguousSubstringBeatsScatteredLetters() {
        let ranked = FuzzyMatch.rank(["Toggle Sidebar", "Show Inbox Database"], by: "side") { $0 }
        #expect(ranked.first == "Toggle Sidebar")
    }

    @Test func prefersWordStartsWhenPossible() {
        // "nb" uses the N of Notebook (+10 word start, −3 gap to b),
        // not the n inside "rename" (no bonus, bigger gap).
        #expect(FuzzyMatch.score("nb", in: "Rename Notebook") == 7)
    }

    @Test func tiesFavorShorterThenAlphabetical() {
        let ranked = FuzzyMatch.rank(["New Notebook", "New Note"], by: "new") { $0 }
        #expect(ranked == ["New Note", "New Notebook"])
    }

    @Test func emptyQueryKeepsOriginalOrder() {
        #expect(FuzzyMatch.rank(["b", "a"], by: "  ") { $0 } == ["b", "a"])
    }
}
