# Architecture

This document explains how DocType is put together. It grows with each phase of [docs/PLAN.md](docs/PLAN.md).

## Layers

| Layer | Where | Responsibility | May import |
|---|---|---|---|
| **Core** | `DocTypeCore/` (Swift package) | The rules: notes and frontmatter, the library on disk and its in-memory index, markdown styling decisions, text transforms, commands, search. Unit-tested. | Foundation, CoreServices, os, swift-markdown |
| **App models** | `DocType/App`, `DocType/Editor` controllers | Wire core to AppKit/SwiftUI and hold UI state (selection, open note, autosave). | SwiftUI, AppKit, DocTypeCore |
| **Views** | `DocType/*View.swift` | Lay out state and forward user actions to models. No logic. | SwiftUI, AppKit |

Core never imports SwiftUI or AppKit, so it can later power a headless MCP server.
Check: `grep -rE "import (SwiftUI|AppKit)" DocTypeCore/Sources` must print nothing.

## Conventions

- Every file starts with a short comment saying what it is responsible for. Files stay under ~300 lines.
- **Concurrency.** The app target uses MainActor as its default isolation. Core is nonisolated. All file I/O happens inside the `Library` actor and never on the main thread. With Approachable Concurrency, a plain `nonisolated async` function runs on the *caller's* actor, so CPU-heavy core work called from the UI is marked `@concurrent`.
- **Text ranges.** Editor-facing core APIs use `NSString` and `NSRange` (UTF-16), the same units as `NSTextStorage`.
- Deployment target is macOS 26. Newer APIs need `if #available`.

## Data flows

### Keyboard shortcut → command → action

1. **Menu item.** You press a shortcut, say ⌘N. AppKit offers it to the main menu, where **File ▸ New Note** exists because `AppMenus` generated it from `CommandID.newNote`. The title, menu and shortcut come from `CommandID.info` in core, and the core `Shortcut` is converted to a SwiftUI `KeyboardShortcut` in `Shortcut+Platform.swift`.
2. **Single entry point.** The menu item calls `model.commands.run(.newNote)`. The command palette makes the same call when you pick "New Note". So does the key monitor in `AppDelegate` for alternate shortcuts a menu can't show (⇧⌘P for the palette).
3. **Dispatch.** `CommandRunner.run` checks `isEnabled`, which is the same check that greys out the menu item and hides the command from the palette. An exhaustive `switch` then calls the behavior, here `AppModel.createNote()`.
4. **Core does the work.** `createNote()` calls `Library.createNote(in:)`. The actor picks a free name (`Untitled`, `Untitled 2`, …), writes the file atomically off the main thread, and publishes a new index snapshot.
5. **UI updates.** `AppModel` selects the new note, the editor opens it and takes focus, and the note list shows it from the new snapshot.

Later, MCP tools and `doctype://` URLs will call the same core functions with explicit arguments. `CommandRunner` only supplies UI context such as "the selected notebook".

## Adding a command

1. **Add a case** to `CommandID` in `DocTypeCore/Sources/DocTypeCore/Commands/CommandID.swift`, with a stable raw value such as `"note.duplicate"`.
2. **Build.** The compiler stops at the `info` switch in the same file. Add the title, the menu it belongs to, and the default shortcut(s), or none. The first shortcut is shown in the menu; any others also trigger the command.
3. **Build again.** The compiler now stops at `run` and `isEnabled` in `DocType/App/CommandRunner.swift`. Add the behavior and when it's available. If the behavior is more than a line or two of wiring, put the logic in core (a `Library` method or a pure function) and call it from here.
4. That's all. The menu item, its shortcut and the palette entry are generated. `swift test` checks that no two commands share a shortcut.

## Planned extension points

- **MCP server.** A future `doctype-mcp` executable target in `DocTypeCore/Package.swift`, using the same `Library` actor as the app.
- **DocShelf.** A `doctype://open?path=…` URL scheme mapped to the app's "open note" action. Lookups go through a small `LookupProvider` protocol, with DocShelf (`docshelf://search?q=…`) as its first implementation.
- **Commands.** Every user action is a named command in one registry. Menus, shortcuts, the palette and later MCP tools all call the same core functions.
