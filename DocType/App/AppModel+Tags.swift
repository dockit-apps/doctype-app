// Tag pickers: Add Tag… lists the library's tags (plus "Create tag ‘x’" for
// a new one), Remove Tag… lists the open note's tags. Both change the note
// through the editor, so they're undoable and autosaved.

import DocTypeCore
import Foundation

extension AppModel {
    /// The tag selected in the sidebar, if a tag is selected.
    var selectedTag: String? {
        if case .tag(let tag) = sidebarSelection { tag } else { nil }
    }

    func showAddTagPicker() {
        let current = editor.tags
        let items = tagCounts
            .filter { tag in !current.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame } }
            .map { tag in
                PaletteItem(id: "tag:" + tag.name, title: "#" + tag.name, detail: "\(tag.count)",
                            action: { [weak self] in self?.editor.addTag(tag.name) })
            }
        let known = tagCounts.map(\.name) + current
        showPalette(Palette(placeholder: "Add a tag", items: items) { [weak self] query in
            guard let tag = Frontmatter.cleanedTag(query),
                  !known.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return nil }
            return PaletteItem(id: "new:" + tag, title: "Create tag “\(tag)”", detail: nil,
                               action: { self?.editor.addTag(tag) })
        })
    }

    func showRemoveTagPicker() {
        let items = editor.tags.map { tag in
            PaletteItem(id: "tag:" + tag, title: "#" + tag, detail: nil,
                        action: { [weak self] in self?.editor.removeTag(tag) })
        }
        showPalette(Palette(placeholder: "Remove a tag", items: items))
    }
}
