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
    case find = "edit.find"
    case findAndReplace = "edit.findAndReplace"
    case findNext = "edit.findNext"
    case findPrevious = "edit.findPrevious"
    case bold = "format.bold"
    case italic = "format.italic"
    case inlineCode = "format.inlineCode"
    case link = "format.link"
    case heading1 = "format.heading1"
    case heading2 = "format.heading2"
    case heading3 = "format.heading3"
    case bodyText = "format.bodyText"
    case taskItem = "format.taskItem"
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
        case .find:
            Info(title: "Find…", menu: .edit, defaultShortcuts: [.command("f")])
        case .findAndReplace:
            Info(title: "Find and Replace…", menu: .edit, defaultShortcuts: [.command("f", .option)])
        case .findNext:
            Info(title: "Find Next", menu: .edit, defaultShortcuts: [.command("g")])
        case .findPrevious:
            Info(title: "Find Previous", menu: .edit, defaultShortcuts: [.command("g", .shift)])
        case .bold:
            Info(title: "Bold", menu: .format, defaultShortcuts: [.command("b")])
        case .italic:
            Info(title: "Italic", menu: .format, defaultShortcuts: [.command("i")])
        case .inlineCode:
            Info(title: "Inline Code", menu: .format, defaultShortcuts: [.command("e")])
        case .link:
            Info(title: "Link", menu: .format, defaultShortcuts: [.command("k", .shift)])
        case .heading1:
            Info(title: "Heading 1", menu: .format, defaultShortcuts: [.command("1", .option)])
        case .heading2:
            Info(title: "Heading 2", menu: .format, defaultShortcuts: [.command("2", .option)])
        case .heading3:
            Info(title: "Heading 3", menu: .format, defaultShortcuts: [.command("3", .option)])
        case .bodyText:
            Info(title: "Body Text", menu: .format, defaultShortcuts: [.command("0", .option)])
        case .taskItem:
            Info(title: "Task Item", menu: .format, defaultShortcuts: [.command("l", .shift)])
        }
    }

    public var title: String { info.title }
}
