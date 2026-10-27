// The single registry of user actions. Menus, shortcuts and the command palette
// are generated from this list, and they all run commands through one entry point
// in the app (CommandRunner). See ARCHITECTURE.md › "Adding a command".

/// Every user action DocType offers, by name. The raw value is a stable identifier
/// (used later for user shortcut overrides and MCP tools).
public enum CommandID: String, CaseIterable, Sendable {
    case showCommandPalette = "app.commandPalette"
    case chooseLibrary = "library.choose"
    case newNote = "note.new"
    case newNotebook = "notebook.new"
    case renameNote = "note.rename"
    case moveNote = "note.move"
    case trashNote = "note.trash"
    case renameNotebook = "notebook.rename"
    case toggleSidebar = "view.toggleSidebar"
}

/// The top-level menu a command appears in.
public enum MenuName: String, CaseIterable, Sendable {
    case file = "File"
    case edit = "Edit"
    case format = "Format"
    case view = "View"
    case note = "Note"
}

extension CommandID {
    public struct Info: Sendable {
        public let title: String
        public let menu: MenuName
        /// The first one is shown in the menu; any others also trigger the command.
        public let defaultShortcuts: [Shortcut]
    }

    public var info: Info {
        switch self {
        case .showCommandPalette:
            Info(title: "Command Palette…", menu: .view,
                 defaultShortcuts: [.command("k"), .command("p", .shift)])
        case .chooseLibrary:
            Info(title: "Choose Library…", menu: .file, defaultShortcuts: [.command("o")])
        case .newNote:
            Info(title: "New Note", menu: .file, defaultShortcuts: [.command("n")])
        case .newNotebook:
            Info(title: "New Notebook", menu: .file, defaultShortcuts: [.command("n", .shift)])
        case .renameNote:
            Info(title: "Rename Note", menu: .note, defaultShortcuts: [.command("r", .shift)])
        case .moveNote:
            Info(title: "Move to Notebook…", menu: .note, defaultShortcuts: [.command("m", .shift)])
        case .trashNote:
            Info(title: "Move to Trash", menu: .note, defaultShortcuts: [Shortcut(.delete, .command)])
        case .renameNotebook:
            Info(title: "Rename Notebook…", menu: .file, defaultShortcuts: [])
        case .toggleSidebar:
            Info(title: "Toggle Sidebar", menu: .view, defaultShortcuts: [.command("s", [.control])])
        }
    }

    public var title: String { info.title }
}
