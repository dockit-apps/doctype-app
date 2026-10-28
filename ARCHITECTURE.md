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

### Keystroke → styled text on screen → saved to disk

1. **Key press.** AppKit delivers the key to `MarkdownTextView`, a plain-text `NSTextView` on TextKit 2. `insertText` registers undo and replaces characters in its `NSTextStorage`.
2. **Edit hook.** `NSTextStorage.processEditing()` calls `StyleApplier.textStorage(_:willProcessEditing:range:changeInLength:)` with the edited UTF-16 range and the length change. Here only the block map is updated and the dirty range remembered.
3. **Dirty range.** `BlockMap.update` (core) rescans from the block before the edit. It stops as soon as an unchanged old block starts again, and returns the range to restyle: usually one or two small blocks, but up to the end of the note if the edit opened or closed a code fence.
4. **Styles.** `MarkdownStyler.spans` (core) parses each dirty text block with swift-markdown, converts its UTF-8 columns to UTF-16 ranges (`SourceMapping`), and returns `StyleSpan`s such as `.heading(2)`, `.codeBlock` and `.syntaxMarker`. Code blocks need no parsing.
5. **Attributes.** After the edit is complete (`textDidChange`), `StyleApplier` resets the dirty range to `EditorTheme.baseAttributes` and adds each span's attributes as a separate, attribute-only edit. Changing attributes *during* the edit would make TextKit 2 move the cursor. While an input method is composing, this waits until composition ends.
6. **Hidden syntax.** Each marker span from core has a reveal range (its line, or the whole code block for fences). `EditorTheme` shows markers the cursor touches and draws the others with no size. When the cursor moves to another line, `StyleApplier.selectionDidChange` restyles only the blocks it left and entered. Quote bars, rules and code boxes are drawn behind the text by `BlockDecorations` (TextKit 2 layout fragments).
7. **Autosave.** `textDidChange` marks the note dirty in `EditorController` and restarts a 1-second idle timer.
8. **Save.** When the timer fires (or right away on switching notes, deactivating or quitting), the controller joins the hidden frontmatter and the editor body and calls `Library.save`. The actor writes the file atomically off the main thread, refreshes the note's summary in the index, and publishes a new snapshot; the note list re-sorts.
9. **No echo.** FSEvents ignores our own writes (`IgnoreSelf`), so saving never reloads the editor. Writes by other programs go through `ExternalChangePolicy`: reload when clean, the conflict banner when there are unsaved edits.

**Opening a note** takes a different path: `MarkdownStyler.styleDocument` builds the block map and all spans off the main thread (`@concurrent`), and `StyleApplier.replaceDocument` puts the styled text in with one edit.

### Keyboard shortcut → command → action

1. **Menu item.** You press a shortcut, say ⌘N. AppKit offers it to the main menu, where **File ▸ New Note** exists because `AppMenus` generated it from `CommandID.newNote`. The title and menu come from `CommandID.info` in core. The shortcut comes from core `ShortcutMap` (the defaults in `CommandID.info` with the user's changes from Settings on top, kept in UserDefaults by `ShortcutSettings`), and the core `Shortcut` is converted to a SwiftUI `KeyboardShortcut` in `Shortcut+Platform.swift`. Menus, palette hints and the key monitor all read the same map, so a change in Settings shows everywhere at once.
2. **Single entry point.** The menu item calls `model.commands.run(.newNote)`. The command palette makes the same call when you pick "New Note". So does the key monitor in `AppDelegate` for alternate shortcuts a menu can't show (⇧⌘P for the palette).
3. **Dispatch.** `CommandRunner.run` checks `isEnabled`, which is the same check that greys out the menu item and hides the command from the palette. An exhaustive `switch` then calls the behavior, here `AppModel.createNote()`.
4. **Core does the work.** `createNote()` calls `Library.createNote(in:)`. The actor picks a free name (`Untitled`, `Untitled 2`, …), writes the file atomically off the main thread, and publishes a new index snapshot.
5. **UI updates.** `AppModel` selects the new note, the editor opens it and takes focus, and the note list shows it from the new snapshot.

Later, MCP tools and `doctype://` URLs will call the same core functions with explicit arguments. `CommandRunner` only supplies UI context such as "the selected notebook".

## Adding a command

1. **Add a case** to `CommandID` in `DocTypeCore/Sources/DocTypeCore/Commands/CommandID.swift`, with a stable raw value such as `"note.duplicate"`.
2. **Build.** The compiler stops at the `info` switch in the same file. Add the title, the menu it belongs to, and the default shortcut(s), or none. The first shortcut is shown in the menu; any others also trigger the command.
3. **Build again.** The compiler now stops at `run` and `isEnabled` in `DocType/App/CommandRunner.swift`. Add the behavior and when it's available. If the behavior is more than a line or two of wiring, put the logic in core (a `Library` method or a pure function) and call it from here.
4. That's all. The menu item, its shortcut and the palette entry are generated. `swift test` checks that no two commands share a shortcut and that none is one macOS reserves (`ShortcutMap.reserved`). The command also appears in Settings ▸ Shortcuts, where it can be rebound.

## Planned extension points

- **MCP server.** A future `doctype-mcp` executable target in `DocTypeCore/Package.swift`, using the same `Library` actor as the app.
- **DocShelf.** A `doctype://open?path=…` URL scheme mapped to the app's "open note" action. Lookups go through a small `LookupProvider` protocol, with DocShelf (`docshelf://search?q=…`) as its first implementation.
- **Commands.** Every user action is a named command in one registry. Menus, shortcuts, the palette and later MCP tools all call the same core functions.
