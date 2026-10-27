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
        case .toggleSidebar:
            model.toggleSidebar()
        }
    }

    func isEnabled(_ command: CommandID) -> Bool {
        switch command {
        case .showCommandPalette, .chooseLibrary, .toggleSidebar:
            true
        case .newNote:
            model.hasUsableLibrary
        }
    }

    /// Commands for one menu, in registry order.
    func commands(in menu: MenuName) -> [CommandID] {
        CommandID.allCases.filter { $0.info.menu == menu }
    }
}
