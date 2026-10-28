// The one place where a CommandID turns into an action. Menus, shortcuts and the
// command palette all call `run(_:)`; menus and the palette use `isEnabled(_:)`.
// Both switches are exhaustive, so a new command can't be forgotten here.

import AppKit
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
        case .addTag:
            model.showAddTagPicker()
        case .removeTag:
            model.showRemoveTagPicker()
        case .toggleSidebar:
            model.toggleSidebar()
        case .find:
            model.editor.performFind(.showFindInterface)
        case .findAndReplace:
            model.editor.performFind(.showReplaceInterface)
        case .findNext:
            model.editor.performFind(.nextMatch)
        case .findPrevious:
            model.editor.performFind(.previousMatch)
        case .searchNotes:
            model.searchFocusRequest += 1
        case .bold:
            model.editor.format { Formatting.toggle(.strong, in: $0, selection: $1) }
        case .italic:
            model.editor.format { Formatting.toggle(.emphasis, in: $0, selection: $1) }
        case .inlineCode:
            model.editor.format { Formatting.toggle(.code, in: $0, selection: $1) }
        case .link:
            model.editor.format { Formatting.link(in: $0, selection: $1) }
        case .heading1:
            model.editor.format { Formatting.heading(1, in: $0, selection: $1) }
        case .heading2:
            model.editor.format { Formatting.heading(2, in: $0, selection: $1) }
        case .heading3:
            model.editor.format { Formatting.heading(3, in: $0, selection: $1) }
        case .bodyText:
            model.editor.format { Formatting.heading(0, in: $0, selection: $1) }
        case .taskItem:
            model.editor.format { Formatting.toggleTask(in: $0, selection: $1) }
        case .insertTable:
            model.editor.insertTable()
        case .addRowAbove:
            model.editor.performTableOperation(.addRowAbove)
        case .addRowBelow:
            model.editor.performTableOperation(.addRowBelow)
        case .addColumnLeft:
            model.editor.performTableOperation(.addColumnLeft)
        case .addColumnRight:
            model.editor.performTableOperation(.addColumnRight)
        case .deleteRow:
            model.editor.performTableOperation(.deleteRow)
        case .deleteColumn:
            model.editor.performTableOperation(.deleteColumn)
        case .alignColumnLeft:
            model.editor.performTableOperation(.align(.left))
        case .alignColumnCenter:
            model.editor.performTableOperation(.align(.center))
        case .alignColumnRight:
            model.editor.performTableOperation(.align(.right))
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
        case .addTag:
            model.selectedNotePath != nil
        case .removeTag:
            model.selectedNotePath != nil && !model.editor.tags.isEmpty
        case .find, .findAndReplace, .findNext, .findPrevious:
            model.selectedNotePath != nil
        case .searchNotes:
            model.hasUsableLibrary
        case .addRowAbove, .addRowBelow, .addColumnLeft, .addColumnRight, .deleteRow, .deleteColumn,
             .alignColumnLeft, .alignColumnCenter, .alignColumnRight:
            model.selectedNotePath != nil && model.editor.hasFocus && model.editor.isInTable
        case .bold, .italic, .inlineCode, .link:
            // Only while typing in the note (or a table cell), so they never touch the title field.
            model.selectedNotePath != nil && model.editor.hasFocus
        case .heading1, .heading2, .heading3, .bodyText, .taskItem, .insertTable:
            // Whole lines: not inside a table cell.
            model.selectedNotePath != nil && model.editor.hasFocus && !model.editor.isEditingTableCell
        }
    }

    /// Commands for one menu, in registry order.
    func commands(in menu: MenuName) -> [CommandID] {
        CommandID.allCases.filter { $0.info.menu == menu }
    }
}
