// The one place where a CommandID turns into an action. Menus, shortcuts and the
// command palette all call `run(_:)`; menus and the palette use `isEnabled(_:)`.
// Both switches are exhaustive, so a new command can't be forgotten here.

import DocTypeCore

final class CommandRunner {
    unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func run(_ command: CommandID) {
        guard isEnabled(command) else { return }
        switch command {
        case .showCommandPalette:
            model.showCommandPalette()
        case .chooseLibrary:
            model.isChoosingLibrary = true
        case .newNote:
            Task { await model.createNote() }
        case .newNotebook:
            Task { await model.createNotebook() }
        case .renameNote:
            model.titleFocusRequest += 1
        case .moveNote:
            model.showMoveNotePicker()
        case .trashNote:
            Task { await model.trashSelectedNote() }
        case .renameNotebook:
            model.beginRenamingNotebook(model.selectedNotebook)
        case .toggleSidebar:
            model.toggleSidebar()
        }
    }

    func isEnabled(_ command: CommandID) -> Bool {
        switch command {
        case .showCommandPalette, .chooseLibrary, .toggleSidebar:
            true
        case .newNote, .newNotebook:
            model.hasUsableLibrary
        case .renameNote:
            model.selectedNotePath != nil
        case .moveNote:
            model.hasUsableLibrary && model.selectedNotePath != nil
        case .trashNote:
            // In the editor, ⌘⌫ keeps its usual meaning: delete to the start of the line.
            model.selectedNotePath != nil && !model.editor.hasFocus
        case .renameNotebook:
            !model.selectedNotebook.isEmpty
        }
    }

    /// Commands for one menu, in registry order.
    func commands(in menu: MenuName) -> [CommandID] {
        CommandID.allCases.filter { $0.info.menu == menu }
    }
}
