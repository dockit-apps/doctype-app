# Architecture

This document explains how DocType is put together: its layers, the two main data flows, the editor's pieces, the measured performance and the known limits. The decisions behind them, phase by phase, are in [docs/PLAN.md](docs/PLAN.md).

## Layers

| Layer | Where | Responsibility | May import |
|---|---|---|---|
| **Core** | `DocTypeCore/` (Swift package) | The rules: notes and frontmatter, the library on disk and its in-memory index, markdown styling decisions, text transforms, commands, search. Unit-tested. | Foundation, CoreServices, os, swift-markdown |
| **App models** | `DocType/App`, `DocType/Editor` controllers | Wire core to AppKit/SwiftUI and hold UI state (selection, open note, autosave). | SwiftUI, AppKit, DocTypeCore |
| **Views** | `DocType/**/…View.swift`, `NoteRow`, `SettingsView` | Lay out state and forward user actions to models. No logic. | SwiftUI, AppKit |

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

## The editor

One `NSTextView` on TextKit 2 (`MarkdownTextView`) shows the note's body. The frontmatter is kept by `EditorController`, shown as tags above the text, and joined back on save. `EditorController` is split by concern into extension files: editing keys, tags, images, attachments, tables and external changes.

- **Hidden syntax.** Markdown stays in the text. Markers the cursor isn't on are drawn with no size (see the keystroke flow above). The text column is at most 70 digit widths and centered.
- **Decorations.** `BlockDecorations` returns a custom layout fragment for each paragraph that needs drawing: code boxes, quote bars, rules, bullets, checkboxes, images and table rows.
- **Images** are measured from file headers before a note appears. Their thumbnails are decoded downsampled off the main thread into a 64 MB cache (`ImageStore`). Width is stored as `![alt|300](path)`.
- **Tables.** A table's Markdown stays in the note, hidden. `EditorTheme+Tables` lays out each row: wrapped cells, `<br>` as a line break, every row as tall as its tallest cell. `BlockDecorations+Tables` draws the rows. The cell being edited gets a real text view laid over it (`TableCellSession`, `TableCellEditor`), and every keystroke there is written straight into the note (`TableCellText` maps `<br>` and `\|` both ways). The note's own cursor never stays in a table: arriving there opens the cell.
  - *Width.* A table never runs past the text column. A table a little too wide tightens its cell padding before any column wraps. A table gets at most `EditorTheme.maximumTableColumns` columns (eight, as many as fit the text column at a readable width). After that, Add Column is disabled and the "+" button is hidden. A wider table written elsewhere still opens and fits, with narrower columns.
  - *Selection and Find.* Since the Markdown under a table is hidden, the table draws the note's selection itself: whole cells when it reaches past one cell, the selected text when it's inside one. Find's highlights come from the cells' layout too (`MarkdownTextView+Find` answers the find bar's `rectsForCharacterRange:` and `drawCharactersInRange:forContentView:` for matches in tables).
  - *Rows without pipes.* GFM goes on with a table until a blank line, so a line of text right under a table is a row (GitHub shows it as one). `TableEditing.table(at:)` asks cmark-gfm about such lines, so the rows edited are the rows drawn. Leaving a table downward lands past a blank line, and typing or pasting on the line right under a table puts a blank line in first, so text written there stays a paragraph.
  - *Markers.* Drawn cells always hide `**` and other markers; the cell editor shows them on the cursor's line, and the column widens to fit them instead of wrapping.
- **Read-only notes.** A file that isn't UTF-8 is decoded anyway (`NoteText`), shown, and never saved, so its encoding is never changed.

## Undo

The note has one undo history, the window's `UndoManager`.
- Typing in the note uses NSTextView's own undo.
- Typing in a table cell registers steps on the same history, grouped like typing (`TableCellSession`). The cell editor has no undo of its own.
- Commands apply core `TextEdit`s through `EditorController.apply`, one step each.
- Tag changes register their own steps.

Two AppKit details shape this:
- **⌘Z goes to the window.** NSTextView doesn't handle `undo:`; NSWindow does, with the window's undo manager.
- **Some undos are silent.** NSTextView undoes an edit made in code without calling `textDidChange` and without moving the cursor. `EditorController.noteDidUndoOrRedo` therefore finishes any change an undo leaves unstyled: it restyles, marks the note for autosave, and puts the cursor at the change.

Before each undo or redo, an open table cell closes. Afterwards, the cell where the change landed opens.

## The library on disk

- **`Library`** is an actor and the only code that touches files. It owns an in-memory `LibraryIndex` (summaries, notebook tree, tags, folded search text) and publishes a new snapshot after every change. There's no persistent index; a scan of 1,000 notes takes about 0.1–0.3 s.
- **`FolderWatcher`** (FSEvents, ignoring our own writes) batches outside changes, and the library re-reads only what changed.
- **External changes to the open note** go through `ExternalChangePolicy`: reload when there are no unsaved edits, the banner when there are. Whichever version you give up is saved as `<name> (conflict <date>).md`.
- **Writes are atomic** (a temp file, then a rename), so a crash never leaves half a note.

## Settings

`Settings` (⌘,) has one pane, Shortcuts. Core `ShortcutMap` holds the user's changes over each command's defaults: it refuses a shortcut that's in use or reserved by macOS, and stores the changes as plain strings. `ShortcutSettings` keeps them in UserDefaults and records new ones from key presses.

## Performance

These are the three budgets from the plan. Measured on 2026-10-28 on the developer's Mac, using a release build and the 1,000-note fixture library (`Scripts/make-fixtures.swift`):

| Budget | Measured | How |
|---|---|---|
| Launch to an editable note under 1 s | 385–545 ms, ordinary note or the 5,000-line note | `LaunchTimer` log line (`log show --predicate 'subsystem == "io.github.dockit-apps.doctype" AND category == "launch"'`), 10 warm launches. Cold launches (after `sudo purge`) not measured. |
| No file I/O on the main thread | none | `Library` has DEBUG `dispatchPrecondition`s on every read and write. Switching through 40 notes under lldb never trips them. |
| Smooth typing in a 5,000-line note | per keystroke 0.07 ms median, 0.8 ms worst (budget 1 / 8 ms) | `PerformanceTests` in release (`swift test -c release`). |

Other measurements:
- Styling the whole 5,000-line note when it opens: 63 ms.
- Search per keystroke: 2 ms at worst (budget 50 ms).
- Library scan: 120 ms warm, about 210 ms on a cold first run (budget 500 ms).
- Typing in a 1,000-line code block: about 1 ms per keystroke.
- A 300-row table: about 29 ms per keystroke in a *debug* build. Normal tables take a few ms.
- Idle: 0–0.7% CPU and about 95 MB of memory in a debug build after switching through 40 notes.

## Known limitations

- A selection that covers whole table rows is also drawn by NSTextView to the right of the table, as for any selected line break.
- Bare URLs are links in the editor, through DocType's own detector (`BareURL`), because swift-markdown has no GFM autolink extension.
- One app test, `thumbnailsAreDecodedSmall`, failed now and then in earlier runs (waiting for a thumbnail). It passed all 50 repeated runs in the last audit. The cause wasn't found.

## Pitfalls we hit

- **Attributes during an edit.** Changing attributes inside `willProcessEditing` makes TextKit 2 move the cursor. Styling happens after the edit, as a separate attribute-only edit.
- **TextKit 1 fallback.** Touching `NSTextView.layoutManager` silently switches the view to TextKit 1. DEBUG builds assert on it.
- **Objective-C exceptions.** They crash at once (`NSApplicationCrashOnExceptions`) instead of leaving Swift concurrency in a broken state.
- **Undo groups in tests.** In app tests, the run loop may not end an undo group between "key presses" while other tests run. Tests that check undo steps group them by hand (`EditorTableTests.groupUndoByHand`).
- **Key modifiers.** `NSApp.currentEvent` can be an older event. The table cell editor reads modifier keys from the key press it is handling.
- **Two parsers, one table.** The styler takes a table's rows from cmark-gfm, while editing used to look only for lines with pipes. A line of text typed under a table was drawn as a row but couldn't be edited as one. Table lookups now defer to cmark-gfm whenever a line without pipes follows the rows.
- **Find in hidden text.** NSTextView's find bar places its highlights from the text's own layout, which for a table is hidden. NSTextView doesn't declare its find-bar client methods, so `MarkdownTextView+Find` overrides them by selector and calls NSTextView's own through their implementation.
- **`log` in zsh.** In zsh, `log` is a shell builtin. Use `/usr/bin/log show` to read the app's log.

## Planned extension points

- **MCP server.** A future `doctype-mcp` executable target in `DocTypeCore/Package.swift`, using the same `Library` actor as the app.
- **DocShelf.** A `doctype://open?path=…` URL scheme mapped to the app's "open note" action. Lookups go through a small `LookupProvider` protocol, with DocShelf (`docshelf://search?q=…`) as its first implementation.
- **Commands.** Every user action is a named command in one registry. Menus, shortcuts, the palette and later MCP tools all call the same core functions.
