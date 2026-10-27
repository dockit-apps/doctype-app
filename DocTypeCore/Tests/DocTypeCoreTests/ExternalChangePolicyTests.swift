// Tests describing how the editor reacts to the open note changing on disk.

import Testing
@testable import DocTypeCore

struct ExternalChangePolicyTests {
    @Test func unchangedContentIsIgnored() {
        #expect(ExternalChangePolicy.action(
            diskText: "same", lastSyncedText: "same", hasUnsavedEdits: true, conflictPending: false) == .ignore)
    }

    @Test func cleanEditorReloadsSilently() {
        #expect(ExternalChangePolicy.action(
            diskText: "new", lastSyncedText: "old", hasUnsavedEdits: false, conflictPending: false) == .reload)
    }

    @Test func unsavedEditsShowTheConflictBanner() {
        #expect(ExternalChangePolicy.action(
            diskText: "new", lastSyncedText: "old", hasUnsavedEdits: true, conflictPending: false) == .showConflict)
    }

    @Test func pendingConflictStaysAConflictEvenIfDiskMatchesAgain() {
        #expect(ExternalChangePolicy.action(
            diskText: "old", lastSyncedText: "old", hasUnsavedEdits: true, conflictPending: true) == .showConflict)
    }

    @Test func keepMineCopiesDiskVersionThenKeepsEditorText() {
        let resolution = ExternalChangePolicy.resolve(.keepMine, editorText: "mine", diskText: "theirs")
        #expect(resolution == .init(copyText: "theirs", finalText: "mine"))
    }

    @Test func useDiskVersionCopiesEditorTextThenLoadsDisk() {
        let resolution = ExternalChangePolicy.resolve(.useDiskVersion, editorText: "mine", diskText: "theirs")
        #expect(resolution == .init(copyText: "mine", finalText: "theirs"))
    }

    @Test(arguments: [ExternalChangePolicy.Choice.keepMine, .useDiskVersion])
    func noChoiceLosesText(choice: ExternalChangePolicy.Choice) {
        let resolution = ExternalChangePolicy.resolve(choice, editorText: "mine", diskText: "theirs")
        #expect(Set([resolution.copyText, resolution.finalText]) == ["mine", "theirs"])
    }
}
