// Builds the menu bar from the command registry: every command appears in its
// menu with its shortcut, greyed out when it can't run.

import DocTypeCore
import SwiftUI

struct AppMenus: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) { items(for: .file) }
        CommandGroup(after: .textEditing) { items(for: .edit) }
        // Replaces SwiftUI's own sidebar item so ⌃⌘S isn't bound twice.
        CommandGroup(replacing: .sidebar) { items(for: .view) }
        // Menus without commands yet (Format and Note fill up in later phases) stay hidden.
        if !model.commands.commands(in: .format).isEmpty {
            CommandMenu(MenuName.format.rawValue) { items(for: .format) }
        }
        if !model.commands.commands(in: .note).isEmpty {
            CommandMenu(MenuName.note.rawValue) { items(for: .note) }
        }
    }

    private func items(for menu: MenuName) -> some View {
        ForEach(model.commands.commands(in: menu), id: \.self) { command in
            Button(command.title) { model.commands.run(command) }
                .keyboardShortcut(command.info.defaultShortcuts.first?.keyboardShortcut)
                .disabled(!model.commands.isEnabled(command))
        }
    }
}
