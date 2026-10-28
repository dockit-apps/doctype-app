// Adding and removing the open note's tags. The frontmatter isn't in the text
// view, so a tag change registers its own undo action on the editor's undo
// manager: ⌘Z undoes it like typing, and autosave writes it like typing.

import AppKit
import DocTypeCore

extension EditorController {
    func addTag(_ tag: String) {
        setTags(Frontmatter.adding(tag, to: tags), actionName: "Add Tag")
    }

    func removeTag(_ tag: String) {
        setTags(Frontmatter.removing(tag, from: tags), actionName: "Remove Tag")
    }

    private func setTags(_ newTags: [String], actionName: String) {
        guard path != nil, !isReadOnly, newTags != tags else { return }
        replaceFrontmatter(with: Frontmatter.settingTags(newTags, in: frontmatter?.raw), actionName: actionName)
    }

    /// Swaps the frontmatter block (`""` for none) as one undoable change.
    private func replaceFrontmatter(with raw: String, actionName: String) {
        let previous = frontmatter?.raw ?? ""
        let undoManager = textView.undoManager
        undoManager?.registerUndo(withTarget: self) { $0.replaceFrontmatter(with: previous, actionName: actionName) }
        undoManager?.setActionName(actionName)
        frontmatter = raw.isEmpty ? nil : Frontmatter.split(raw).frontmatter
        tags = frontmatter?.tags ?? []
        isDirty = true
        scheduleAutosave()
    }
}
