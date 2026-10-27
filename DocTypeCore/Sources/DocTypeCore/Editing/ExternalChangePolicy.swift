// What the editor does when the open note changes on disk, and how a conflict is resolved.
//
// What it does
// - The disk text equals what we last loaded or saved → ignore. This covers `touch`,
//   a git checkout that rewrites identical content, and late echoes of our own saves.
// - The editor has no unsaved edits → reload silently, keeping the caret where it was.
//   The common cases (git pull, an AI tool editing a note you're only reading)
//   need no decision from you.
// - The editor has unsaved edits → show the banner and pause autosave for this note
//   until you choose. Autosave would otherwise overwrite the other program's change.
//
// Resolving, with the fixed rule that no choice ever loses text:
// - "Keep Mine": the disk version is saved as a conflict copy, then your text is saved.
// - "Use Disk Version": your text is saved as a conflict copy, then the disk text loads.
// - Leaving the note (switching notes, quitting) while the banner is up counts as
//   "Use Disk Version". The file on disk stays as the other program left it, and
//   your edits are safe in the copy.
// - Further external changes while the banner is up just update the pending disk text.
//
// Alternatives considered
// - Last writer wins (no banner): simplest, but silently discards one side.
// - Automatic three-way merge: needs a common ancestor and a merge UI; far beyond the MVP.
// - Modal alert: interrupts typing; a non-modal banner lets you finish the sentence first.
// - "Leaving = Keep Mine": also lossless, but it would overwrite a change another
//   program (e.g. git) just made, which is the more surprising outcome.

public enum ExternalChangePolicy {
    public enum Action: Equatable, Sendable {
        case ignore
        case reload
        case showConflict
    }

    /// Decides how to react to the open note's file changing on disk.
    /// - Parameters:
    ///   - diskText: the file's current content.
    ///   - lastSyncedText: the content we last loaded from or saved to disk.
    ///   - hasUnsavedEdits: the editor has changes not yet written.
    ///   - conflictPending: the banner is already showing.
    public static func action(
        diskText: String, lastSyncedText: String, hasUnsavedEdits: Bool, conflictPending: Bool
    ) -> Action {
        if conflictPending { return .showConflict }
        if diskText == lastSyncedText { return .ignore }
        return hasUnsavedEdits ? .showConflict : .reload
    }

    public enum Choice: Sendable {
        case keepMine
        case useDiskVersion
    }

    /// The two steps of resolving a conflict, always in this order:
    /// first save `copyText` as a conflict copy, then make `finalText` the note's content.
    public struct Resolution: Equatable, Sendable {
        public let copyText: String
        public let finalText: String
    }

    public static func resolve(_ choice: Choice, editorText: String, diskText: String) -> Resolution {
        switch choice {
        case .keepMine: Resolution(copyText: diskText, finalText: editorText)
        case .useDiskVersion: Resolution(copyText: editorText, finalText: diskText)
        }
    }
}
