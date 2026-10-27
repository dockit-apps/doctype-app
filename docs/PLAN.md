# DocType — MVP Implementation Plan

## Context

DocType is a native macOS markdown note app that replaces Inkdrop for two people's lecture, engineering and personal notes. The repo (`doctype-app`) currently holds only a SwiftPM "hello world" executable (`Package.swift`, tools-version 6.4, `ApproachableConcurrency` on) and a one-line README. This plan splits the MVP into 14 small phases (0–13). The app builds and runs after every phase. Open questions (section 6) are answered here as they're decided.

**Technical defaults chosen here (no input needed, but say so if you disagree):**
- **Xcode app project + local Swift package.** SwiftPM alone can't produce a proper `.app`: it has no Info.plist, bundle ID, asset catalog, signing or URL schemes. The existing package is moved into `DocTypeCore/` and becomes the core library.
- **Single main window** (`Window` scene) for the MVP. Commands then reach the one `AppModel` directly. Multiple windows later means switching to `@FocusedValue`.
- **Delete moves files to the system Trash**, so there is no confirmation dialog.
- ~~**Editor-side code highlighting is preview-only for the MVP.**~~ Changed after Phase 6 review: the editor now highlights code too (see section 5).
- **Self-written changes are ignored** through FSEvents' `IgnoreSelf` flag. External changes to the open note reload it if it has no unsaved edits. If it does, a banner offers **Reload / Keep Mine**, and autosave for that note pauses until you choose.
- **Tags are matched case-insensitively** (`Algo` = `algo`) and shown as first written. New frontmatter is written in flow style (`tags: [a, b]`). Existing frontmatter keeps its list style.

---

## 1. Module / folder layout

```
doctype-app/
├── README.md                      # what it is, how to build/test, fixtures
├── ARCHITECTURE.md                # layers, both data flows, how to add a command, extension points
├── DocType.xcodeproj              # app target only; Xcode "buildable folders" → adding files doesn't touch pbxproj
├── DocType/                       # APP TARGET (SwiftUI + AppKit). Default actor isolation: MainActor
│   ├── App/
│   │   ├── DocTypeApp.swift       # @main, Window scene, installs AppMenus
│   │   ├── AppModel.swift         # @Observable UI state: index snapshot, sidebar selection, search, open note
│   │   └── CommandRunner.swift    # CommandID → action (one switch) + isEnabled (one switch)
│   ├── Menus/AppMenus.swift       # SwiftUI Commands generated from the registry
│   ├── Palette/CommandPaletteView.swift   # floating glass palette; also used as a picker (notebooks, tags)
│   ├── Sidebar/SidebarView.swift
│   ├── NoteList/NoteListView.swift, NoteRow.swift
│   ├── Editor/
│   │   ├── EditorView.swift       # NSViewRepresentable: NSScrollView + MarkdownTextView, title field
│   │   ├── MarkdownTextView.swift # NSTextView subclass (TextKit 2): task-marker clicks, focus tracking
│   │   ├── EditorController.swift # load/apply TextEdits/undo-aware edits/autosave/conflict banner state
│   │   ├── StyleApplier.swift     # NSTextStorageDelegate: BlockMap + MarkdownStyler → attributes
│   │   └── EditorTheme.swift      # Style → NSFont/NSColor (dynamic colors, light/dark)
│   ├── Preview/
│   │   ├── PreviewView.swift      # NSViewRepresentable WKWebView + message handler for checkboxes
│   │   └── Web/                   # preview.html, preview.css, preview.js, vendor/highlight.js (+LICENSE)
│   └── Resources/Assets.xcassets
├── DocTypeCore/                   # LOCAL SWIFT PACKAGE — imports Foundation, CoreServices, os, Markdown only
│   ├── Package.swift              # macOS 26, Swift 6 mode, dependency: swift-markdown (.upToNextMinor)
│   ├── Sources/DocTypeCore/
│   │   ├── Notes/       NoteSummary.swift (title, snippet, tags, tasks, mtime), Frontmatter.swift, TaskCounter.swift
│   │   ├── Library/     Library.swift (actor: all file I/O + index), LibraryIndex.swift (value snapshot),
│   │   │                LibraryScanner.swift, FolderWatcher.swift (FSEvents), FileNaming.swift
│   │   ├── Markdown/    BlockMap.swift, MarkdownStyler.swift, Style.swift (Style + StyleSpan),
│   │   │                SourceMapping.swift (UTF-8 columns → UTF-16), HTMLRenderer.swift
│   │   ├── Editing/     TextEdit.swift, Formatting.swift, ListContinuation.swift, TaskToggle.swift
│   │   ├── Search/      NoteSearch.swift, FuzzyMatch.swift
│   │   └── Commands/    CommandID.swift (enum + metadata switch), Shortcut.swift
│   └── Tests/DocTypeCoreTests/    # Swift Testing; roughly one test file per source file; Fixtures/
└── Scripts/make-fixtures.swift    # generates a 1,000-note library + a 5,000-line note for perf checks
```

**Conventions**
- Every file starts with a 1–3 line comment saying what it is responsible for. Keep files under ~300 lines.
- **Core** holds the rules: parsing, styling decisions, text transforms, file operations, index and search. The **app models** (`AppModel`, `EditorController`, `CommandRunner`) wire core to AppKit and SwiftUI and hold UI state. **Views** lay out state and call model methods, with no logic.
- **Concurrency.** The app target uses MainActor default isolation. Core is nonisolated. All file I/O happens inside the `Library` actor, which has a DEBUG `dispatchPrecondition(condition: .notOnQueue(.main))` in its read and write helpers. With `ApproachableConcurrency`, a plain `nonisolated async` function runs on the caller's actor, which means the main actor when a view calls it. CPU-heavy one-offs, such as preparing a large note's initial styling, are therefore marked `@concurrent`.
- **Editor-facing core APIs take `NSString` + `NSRange` (UTF-16)**, which is what `NSTextStorage` uses. That avoids index conversions and full-document `String` copies on the keystroke path.
- **Deployment target is macOS 26.0.** You develop on macOS 27 / Xcode 27, so any newer API needs `if #available`.
- Each "Builds" bullet below is roughly one commit. A phase is done when the app builds, `swift test` passes and that phase's checks pass.
- **No AI attribution in git history.** Claude Code must never add itself as co-author or attribution in any commit message or PR description: no `Co-Authored-By: Claude …` trailer and no "Generated with Claude Code" line. Commits and PRs are authored only by the two of you.

---

## 2. Data flows

### (a) Keystroke → styled text on screen → saved to disk

1. **Key press.** AppKit delivers `keyDown` to `MarkdownTextView` (an `NSTextView` with TextKit 2). `insertText` registers undo and replaces the characters in its `NSTextStorage`.
2. **Edit hook.** `NSTextStorage.processEditing()` calls `StyleApplier.textStorage(_:willProcessEditing:range:changeInLength:)` with the edited UTF-16 range and the length delta. Apple documents this hook as the place where delegates may change attributes. It runs *before* attribute fixing, so emoji and CJK characters in restyled ranges still get font fallback. The step is skipped while the view has marked text from an input method and runs on commit.
3. **Find the dirty block.** `StyleApplier` calls core `BlockMap.update(text: textStorage.mutableString, editedRange:, delta:)`. The map shifts later block offsets and returns the **dirty range**. Normally that is the enclosing block, or two blocks when a blank line was added or removed. It only grows when a code-fence or frontmatter delimiter line changed, and then it covers just the blocks whose kind flipped.
4. **Compute styles (core, pure).** `MarkdownStyler.spans(text:range:blocks:)` handles each dirty block. A code or frontmatter block gets fixed spans. A text block's substring is parsed with swift-markdown (`Document(parsing:)`) and walked. Node ranges are converted from swift-markdown's **UTF-8 byte columns** to UTF-16 document offsets, and marker ranges (`**`, `#`, `` ` ``, `[ ]`) are derived from node bounds. The result is `[StyleSpan(range, style)]`, such as `.heading(2)`, `.strong`, `.syntaxMarker` or `.codeBlock`.
5. **Apply attributes (app).** `StyleApplier` resets the dirty range to the base attributes and sets `EditorTheme.attributes(for: span.style)` for each span. All of this happens inside the same `processEditing` pass. `NSTextContentStorage` therefore sees one change, and `NSTextLayoutManager` lays out again only the affected paragraphs that are in the viewport. An `OSSignposter` interval named "restyle" wraps steps 3–5.
6. **Mark dirty.** `textDidChange` reaches `EditorController`, which marks the note dirty. It cancels any pending autosave task and starts a new one that waits for 1 s of idle time.
7. **Save trigger.** The save runs when the timer fires, or right away on note switch, app deactivation, window close or quit. The controller takes a `textView.string` snapshot on the main actor and calls `await library.save(path:text:)`.
8. **Atomic write (off-main).** The `Library` actor runs `Data(text.utf8).write(to:options: .atomic)`, which writes a temp file and then renames it, so a crash never leaves half a note. It records the text as that note's last-known disk content, rebuilds its `NoteSummary` (title, snippet, tags, task counts, mtime) from the text without re-reading the file, and publishes a new `LibraryIndex` snapshot on its `AsyncStream`.
9. **UI update.** `AppModel` (main actor) receives the snapshot. The note list re-sorts, so the note moves to the top, and its snippet and task progress update.
10. **Echo.** FSEvents leaves out our own write because of `IgnoreSelf`, so the editor never reloads under your cursor. Writes from other processes (git, vim, and later the MCP server) do arrive and go through the reload/conflict path from Phase 3.

### (b) Keyboard shortcut → command → action

1. **Menu item.** You press ⌘B with the editor focused. AppKit's key-equivalent pass finds **Format ▸ Bold** in the main menu; a plain-text `NSTextView` doesn't claim ⌘B. That menu item exists because `AppMenus` generated it from `CommandID.bold`'s metadata in core: title "Bold", menu `.format`, `Shortcut(key: "b", modifiers: .command)`, mapped to a SwiftUI `KeyboardShortcut`.
2. **Single entry point.** The item's action calls `commandRunner.run(.bold)`. The command palette (choosing "Bold") and the alternate-shortcut key monitor (used for ⇧⌘P) make **the same call**.
3. **Dispatch.** `CommandRunner.run` checks `isEnabled(.bold)`, which is true when the editor is first responder. This is the same check that greys out the menu item and hides the command from the palette. An exhaustive `switch` then calls `editor.apply(Formatting.toggleStrong)`.
4. **Pure transform (core).** `EditorController` passes `textStorage.mutableString` and `selectedRange` to `Formatting.toggleStrong(text:selection:)`. It returns a `TextEdit(range, replacement, selectionAfter)` that wraps the selection or word in `**`, or unwraps it if it is already bold. Unit tests cover it.
5. **Undo-aware apply.** The controller calls `shouldChangeText(in:replacementString:)`, then `replaceCharacters`, then `didChangeText()`, and sets the selection. The result is exactly one undo step, and it re-enters flow (a) at step 2 for restyling and autosave.
6. **Library commands.** Commands such as `.newNote` follow the same `run` path. The case body is `Task { let path = try await library.createNote(in: notebook, tags: selectedTag); appModel.open(path) }`, which writes the file, publishes a snapshot, selects the note in the list and focuses the title field. Errors surface through `appModel.presentError`.
7. **Later.** MCP tools and `doctype://` URLs will call the *same core functions* (the `Library` methods and the `Formatting` / `TaskToggle` transforms) with explicit arguments. `CommandRunner` stays a thin adapter that supplies UI context such as "current note" and "selection".

---

## 3. Extension points (designed now, not built)

1. **MCP server.** `Library(root: URL)` covers read, list, search and edit with no UI. Later we add a `doctype-mcp` executable target to `DocTypeCore/Package.swift`. To keep that possible:
   - Core never reads UserDefaults or bookmarks. The root URL is passed in.
   - Core has no singletons.
   - Every mutating operation is a `Library` method.
   - Because writes are atomic and watched, the app picks up MCP edits like any other external edit, and the dirty-note banner protects text you are typing.
2. **DocShelf.** Notes are identified by their path relative to the library, so `doctype://open?path=Algorithms/Graphs.md` maps to `AppModel.open(path:)`, which the note list and launch restore already use. Planned for later, documented in ARCHITECTURE.md only:
   - a `CFBundleURLTypes` entry in Info.plist and `.onOpenURL`;
   - core `protocol LookupProvider { var name: String { get }; func lookupURL(for query: String) -> URL? }`;
   - `DocShelfLookup` building `docshelf://search?q=…`;
   - a "Look Up Selection in DocShelf" command.
3. **Command system.** This is built in Phase 4. Any command behavior that touches notes or text lives in core, so MCP tools can call it without UI.

## 4. Why no persistent index

The note list, tags and search use an in-memory `LibraryIndex` built by a background scan.
- **The scan is cheap.** 1,000 notes at roughly 5 KB each is about 5 MB to read, and indexing only scans lines; swift-markdown never runs during indexing. That should take a few hundred milliseconds off-main.
- **Launch doesn't wait for it.** The last-open note is read on its own, so the scan never blocks launch.
- **Memory is small.** Keeping all note bodies in memory for search costs about 5 MB.
- **A persistent index would add the problem we're avoiding.** SQLite or a cache must be invalidated against git, other editors and the MCP server, and the files are the source of truth.
- **Revisit trigger.** If Phase 1's measured scan of the 1,000-note fixture goes over 500 ms, or libraries reach about 10,000 notes, add a small JSON cache keyed by (path, mtime, size). Still not SQLite.

---

## 5. Phases

**Changes after the open questions were answered (these override the phase text below where they conflict):**
- **Frontmatter is hidden (Q2).** The editor buffer holds only the note body. When a note opens, `Frontmatter.split` separates the raw frontmatter, which `EditorController` keeps as a small model (`raw` text + `tags`). A **tag bar** above the editor shows the tags as chips, and Add/Remove Tag edit that model. Save writes `frontmatter + body` together. So `BlockMap` never sees frontmatter in the editor, and tag edits register undo on the window's undo manager instead of through the text view. Phase 9's tag bar UI moves into Phase 5's title area as a read-only row; editing arrives in Phase 9.
- **Shortcuts are configurable (Q3).** The core `CommandID` metadata holds the *default* shortcuts. A new **Phase 12 — Shortcut settings** adds a Settings window where each command's shortcut can be recorded or reset. Overrides are stored in UserDefaults (app side; core stays free of UserDefaults). Core validates conflicts. The old Phase 12 becomes Phase 13.
- **Toolchain (Q8).** Both developers use Xcode 27, so `swift-tools-version: 6.4` stays.
- **Code blocks in the editor (added during Phase 6 review).** Fenced code blocks are drawn as one rounded, full-width box (a custom TextKit 2 layout fragment) and syntax-highlighted by a table-driven tokenizer in core (`CodeHighlighter`, about 15 languages). Measured: ~0.6 ms per keystroke in a 1,000-line code block in release builds; unoptimized debug builds take ~25 ms for blocks that large (typical 10–50 line blocks stay well under 1 ms). Per-line incremental tokenizing is the follow-up if huge blocks become common.
- **Markdown syntax is hidden except where the cursor is (changed after Phase 6 review, like Obsidian).** This replaces "syntax stays visible but dimmed". Heading `#`, quote `>`, `---` and setext underlines show (dimmed) only on the cursor's line; a code block's fences and language show only while the cursor is inside that block. Hidden syntax stays in the file and the text; it's just drawn with no size. Quotes get a bar on the left and `---` becomes a drawn rule, so the structure stays visible. Phase 7's inline markers (`**`, `` ` ``, link syntax) follow the same rule.
- **Styling is applied after each edit, not during it.** Changing attributes inside `willProcessEditing` made TextKit 2 move the cursor (typing in the middle of a note jumped lines). The block map still updates during the edit; the attributes follow in a separate attribute-only edit. An app test target (`DocTypeTests`) now types into a real TextKit 2 editor to guard this.
- **Section 7 pieces.** Claude writes first versions, each with a header comment covering what it does, why, and the alternatives, plus tests that describe the behavior. **Fixed rule for the conflict banner:** no choice ever loses text. Whichever version is discarded is first saved next to the note as `<name> (conflict <yyyy-MM-dd HHmmss>).md`. That name is deliberately a normal note, so it shows up in the list and you can't miss it.

Shared tooling:
- **Fixtures.** `Scripts/make-fixtures.swift <dir>` generates 1,000 notes across about 20 nested notebooks, with frontmatter tags, code blocks and tasks, plus `Big/5000-lines.md`.
- **Signposts.** Intervals on launch, scan, open-note, restyle, search and preview render, viewed in Instruments' Points of Interest.
- **Instruments templates.** App Launch, Time Profiler, Hangs, Animation Hitches and File Activity.

### Phase 0 — Project skeleton
**Builds**
- Move the package to `DocTypeCore/` as a library and test target: `platforms: [.macOS(.v26)]`, the swift-markdown dependency, and `ApproachableConcurrency` kept on. Delete the hello-world `Sources/doctype_app` and `Tests/doctype_appTests`.
- Create `DocType.xcodeproj` from the macOS App template:
  - SwiftUI, product name DocType, bundle ID `io.github.dockit-apps.doctype`, deployment target 26.0;
  - Swift 6 mode, Default Actor Isolation set to MainActor;
  - **App Sandbox entitlement removed**, Hardened Runtime kept for notarization later;
  - local package dependency on `DocTypeCore`.
- `DocTypeApp` with a `Window` scene showing an empty 3-column `NavigationSplitView` (`ContentUnavailableView` placeholders). The sidebar gets the system's Liquid Glass automatically.
- README (build: open the project and press ⌘R; test: `cd DocTypeCore && swift test`). ARCHITECTURE.md skeleton (layers and conventions). `.gitignore` additions.
- Optional: a GitHub Actions workflow that runs `swift test` and `xcodebuild build`.

**Uses**
- Xcode project: required for a real `.app` bundle.
- swift-markdown: fixed decision. Pin `.upToNextMinor` because it is pre-1.0.
- Swift Testing: already in use and the modern default.

**Verify**
- `xcodebuild -project DocType.xcodeproj -scheme DocType build` succeeds, and the app launches showing three empty columns with a glass sidebar.
- `cd DocTypeCore && swift test` passes.
- `plutil -extract CFBundleIdentifier raw DocType.app/Contents/Info.plist` prints `io.github.dockit-apps.doctype`.
- `codesign -d --entitlements - DocType.app` shows no `com.apple.security.app-sandbox`.
- `grep -rE "import (SwiftUI|AppKit)" DocTypeCore/` prints nothing. This is the core-purity check, kept in CI.

### Phase 1 — Open a library; sidebar and note list (read-only)
**Builds**
- **Core.**
  - `Frontmatter`: split the `---` block and read `tags` in flow or block style, including quoted values. An unclosed `---` is treated as body.
  - `NoteSummary.make(path:text:modified:)`: title from the filename (see Q1); snippet from the first body lines with markdown markers stripped, skipping the frontmatter and a leading `# heading` that repeats the title.
  - `LibraryScanner`: recursive `.md` enumeration with prefetched `contentModificationDate`, skipping hidden folders (`.git`, `.obsidian`) and packages.
  - `LibraryIndex`: notes keyed by relative path, the notebook tree, and `notes(matching:)` sorted by mtime, newest first.
  - `Library` actor: `open(root:)`, `scan()`, `updates: AsyncStream<LibraryIndex>`.
- **App.**
  - An onboarding "Choose Library…" button using `.fileImporter` with `[.folder]`. The choice is stored as bookmark data, so it survives moving the folder.
  - Sidebar with All Notes and the notebook tree.
  - Note list rows showing title, snippet and relative date.
  - Selecting a notebook filters the list.
- `Scripts/make-fixtures.swift`.

**Uses**
- FileManager enumerator with resource keys: one pass gives paths and mtimes.
- SwiftUI `NavigationSplitView`/`List`/`OutlineGroup`: native sidebar with glass.
- `OSSignposter`: measures the scan.

**Verify**
- Core tests:
  - Frontmatter: none, empty, flow, block, quoted values, CRLF, unclosed.
  - Snippet skips frontmatter and the duplicate heading.
  - Scanner ignores `.git/`, dotfiles and non-`.md` files.
- With the 1,000-note fixture:
  - all notes are listed newest first;
  - the scan signpost is under 500 ms;
  - the window can be resized smoothly during the scan.
- Selecting a notebook shows its notes, including those in subfolders (see Q5).
- Relaunch remembers the library. Moving the library folder in Finder and relaunching still opens it.

### Phase 2 — Plain editor, autosave, launch restore
**Builds**
- **`EditorView` / `MarkdownTextView`.**
  - Created with `NSTextView(usingTextLayoutManager: true)`.
  - `isRichText = false`, undo on.
  - **Smart quotes, smart dashes and text replacement off**, so `"`, `--` and code stay literal.
  - Body font: system 15 pt.
- **`EditorController`.**
  - Opens a note with `await library.read(path)` and sets the text without registering undo.
  - Tracks dirty state and runs a 1 s idle autosave, flushed on switch, deactivate, close and quit.
  - **Clears the undo stack on note switch.**
- **Core.** `Library.read`, and `Library.save` with an atomic write, index entry update and snapshot.
- **Launch.** The last-open note is restored straight away, without waiting for the scan.
- **DEBUG guards.**
  - Assert `textView.textLayoutManager != nil`.
  - Observe `NSTextView.willSwitchToNSLayoutManagerNotification`, which fires if anything touches `.layoutManager` and silently drops to TextKit 1.

**Uses**
- AppKit `NSTextView` with TextKit 2: fixed decision, and it lays out only the viewport, which large notes need.
- `Data.write(.atomic)`: crash-safe writes.
- Swift concurrency (`Task` + `Task.sleep`): debounce without timers.

**Verify**
- Type, wait 1 s, and `cat` shows the change. Type and press ⌘Q immediately, and the last keystroke is on disk.
- Typing `"` and `--` keeps them ASCII.
- After switching notes, ⌘Z does nothing.
- The TextKit 1 fallback notification never fires.
- **With the 1,000-note fixture, launch to an editable note takes under 1 s.** Measure with the App Launch template, warm and after `sudo purge`.
- The DEBUG main-thread I/O preconditions never trip, and File Activity shows no reads or writes on the main thread.
- The saved note moves to the top of the list.
- Typing in the 5,000-line fixture (still unstyled) has no visible lag.

### Phase 3 — Folder watching (external changes)
**Builds**
- **Core `FolderWatcher`.**
  - FSEvents with `FileEvents | NoDefer | IgnoreSelf | WatchRoot` and about 0.3 s latency.
  - Passes batched paths to `Library`, which re-reads changed `.md` files, drops deleted ones, rescans a subtree on `MustScanSubDirs`, and publishes one snapshot per batch.
- **Open note.**
  - If disk content differs from the last-known content and the editor is clean, reload, keeping the selection (clamped) and the scroll position.
  - If the editor is dirty, show a glass banner, **"Changed on disk — Reload / Keep Mine"**, and pause autosave for that note.
- **Library root removed or unmounted.** Show a "Library not found" state.

**Uses**
- CoreServices FSEvents: recursive, and it sees changes from any process. `NSFilePresenter` only sees coordinated writes, which git and most editors don't make.

**Verify**
- `echo "- [ ] x" >> note.md` updates the list in under 1 s, and the open (clean) note shows the new line with the cursor kept.
- `touch` without a content change causes no reload.
- A `git checkout` that changes 200 fixture files leaves a consistent list after about 1 s. The Hangs instrument shows no hangs.
- Typing in the app never triggers a reload.
- Editing the open note in vim while typing in the app shows the banner, and both choices behave as described.
- A Finder rename or move, or a new folder, appears in the list and sidebar.
- Core integration test: write to a temp directory and expect an event within 2 s.

### Phase 4 — Command system and command palette
**Builds**
- **Core.**
  - `enum CommandID: String, CaseIterable` (e.g. `"note.new"`).
  - A `metadata` switch giving title, menu and shortcut(s).
  - `Shortcut` with key, modifiers and a display string such as "⇧⌘P".
  - `FuzzyMatch.score(query:candidate:)`.
- **App.**
  - `CommandRunner` with an exhaustive `run` and `isEnabled`.
  - `AppMenus` generating the File, Edit, Format, View and Note menus from the registry. Standard actions (Undo, Copy, Paste) stay with AppKit's responder chain.
  - `CommandPaletteView`: a floating panel with `.glassEffect(.regular, in: .rect(cornerRadius: 16))`. Arrow keys, Return and Escape use `.onKeyPress`. Each row shows the command's shortcut. The palette can also run as a picker over any list of items.
  - A local key monitor maps an alternate shortcut (⇧⌘P) to the same `run`.
- **First commands:** Show Command Palette, Choose Library…, New Note (creates `Untitled.md` in the current notebook), Toggle Sidebar.
- **ARCHITECTURE.md:** flow (b) and "How to add a command":
  1. Add a case to `CommandID`.
  2. The compiler points to the `metadata` switch; fill in title, menu and shortcut.
  3. The compiler points to `run` / `isEnabled`; add the behavior. Real logic goes in core.
  4. The menu entry, shortcut and palette entry come for free.

**Uses**
- SwiftUI `Commands` / `CommandMenu` / `.keyboardShortcut`: native menu bar and shortcuts.
- SwiftUI `glassEffect`: native Liquid Glass for a floating control.

**Verify**
- Core tests:
  - every command has a title;
  - **no two commands share a shortcut**;
  - display strings are correct;
  - fuzzy ranking cases ("nn" ranks "New Note" above "Rename Notebook").
- ⌘K and ⇧⌘P both open the palette. Typing `new` and pressing Return creates a note, three keystrokes in all. Escape returns focus to the editor.
- The palette lists exactly the enabled commands.
- Every command is in the menu bar with its shortcut shown.
- **Dry run:** add a dummy command. The compiler errors point only at the two switches, and the command then appears in the menu and palette. Revert it.
- With Reduce Transparency on, the palette becomes opaque, which proves it uses native glass.

### Phase 5 — Note and notebook management
**Builds**
- **Core `Library` operations:** `createNote(in:tags:)`, `renameNote`, `moveNote`, `trashNote` (`FileManager.trashItem`), `createNotebook`, `renameNotebook`.
- **Core `FileNaming`:**
  - collision suffix ("Untitled 2");
  - rejects `/`, `:`, a leading `.` and empty names;
  - **case-only rename** (`note` → `Note`) goes through a temp name, because APFS is case-insensitive.
- **Editor title field** above the text, holding the filename (Q1):
  - committing it renames the file;
  - New Note focuses it, and Return moves into the body;
  - the Rename Note command focuses it.
- **Other commands:**
  - Move Note… uses the palette as a notebook picker. Drag onto a sidebar notebook is optional.
  - Delete Note (⌘⌫) trashes the note and selects the next one.
  - New Notebook and Rename Notebook.
  - Any pending autosave is flushed before a file operation on the open note.

**Uses**
- FileManager move, trash and createDirectory: Trash makes delete recoverable.

**Verify**
- Core tests against a temp directory, checking the effect of each operation on disk and in the index:
  - collisions;
  - case-only rename;
  - a notebook rename updates the paths of every nested note.
- ⌘N, type a title, Return, type the body: `Title.md` holds the body after 1 s.
- A deleted note is in the Trash, and Finder's "Put Back" restores it.
- Renaming or moving the open note while typing loses no characters, and the editor stays open.
- Every operation is available from both the menu and the palette.

### Phase 6 — Live styling I: block pipeline
**Builds**
- **Core `BlockMap`:**
  - a line scan into blocks: frontmatter (only at offset 0), fenced code (`` ``` `` / `~~~` with info string, closed by the same character and at least the same length), and text;
  - a blank line ends a block unless the next non-blank line is indented, which keeps list continuations together;
  - `update(…) -> dirtyRange`.
- **Core `MarkdownStyler` and `SourceMapping`:**
  - frontmatter is **never handed to swift-markdown**, which would parse `---\ntags: [a]\n---` as a thematic break plus a setext H2;
  - block-level styles: headings sized by level, fenced code in SF Mono with a subtle background and dimmed fences, frontmatter dimmed, blockquotes, thematic breaks.
- **App.** `StyleApplier` (the `willProcessEditing` hook, skipped while `hasMarkedText()`) and `EditorTheme` with dynamic `NSColor`s.
- **Open-note pipeline.** `BlockMap` and spans for the whole note are prepared `@concurrent` off-main together with the file read, so the note first appears already styled. Initial styling uses the same per-block path as edits.

**Uses**
- swift-markdown: fixed decision, GFM via cmark-gfm.
- `NSTextStorage` attributes: the documented TextKit place for per-range styling.

**Verify**
- **Property test:** for random edit sequences on the fixtures (inserting and deleting fences, blank lines and text), the incrementally updated `BlockMap` and spans equal a from-scratch build.
- Unicode test: in `# Özet ğüşıç 🎓 notes`, the heading span covers exactly the right UTF-16 range.
- Frontmatter is never styled as a heading.
- **5,000-line fixture, typing in the middle:**
  - the restyle signpost has a median under 1 ms and a max under 8 ms;
  - Animation Hitches shows none while holding a key for 10 s.
- Typing an opening fence turns the rest into code (correct GFM), and closing it restores the rest. This one-time re-parse may take up to about 200 ms; Phase 8's auto-closing fence makes it rare.
- The 5,000-line note opens styled in under 300 ms with no unstyled flash.
- Dead-key and IME input (⌥u u → ü, Japanese Kana) composes correctly.
- Switching light/dark updates colors live.

### Phase 7 — Live styling II: inline styles and lists
**Builds**
- Styles for strong, emphasis and strikethrough (markers dimmed), inline code (monospace and background, backticks dimmed), links (text in link color, `(url)` dimmed), autolinks, list markers, task markers `[ ]` / `[x]` (a checked item's text in a secondary color), and table pipes (dimmed).
- Marker ranges are derived from node bounds.

**Uses**
- swift-markdown `MarkupWalker` over inline nodes.

**Verify**
- Span tests for each construct, nesting (`***both***`, ``**bold `code`**``), unclosed markers (`**abc` stays plain) and escapes (`\*`).
- Markers stay visible and dimmed, and caret movement over them is normal.
- Phase 6's performance numbers still hold on an inline-heavy fixture.

### Phase 8 — Editing commands, list continuation, task clicks, find and replace
**Builds**
- **Core `TextEdit` and `Formatting`:**
  - toggle bold, italic and inline code on the selection or the word at the caret;
  - Link inserts `[selection](|)`;
  - Heading 1–3 and Body Text work on the current line(s);
  - Task Item works on the line(s).
- **Core `ListContinuation`:**
  - continues `-` / `*` / `+` / `1.` / `- [ ]`, incrementing numbers and keeping indentation and `> ` prefixes;
  - Return on an empty item ends the list;
  - Return after an opening fence inserts the closing fence.
- **Core `TaskToggle.edit(togglingTaskAt:)`.**
- **App:**
  - the commands with shortcuts (Q3);
  - `textView(_:doCommandBy: insertNewline:)` goes to `ListContinuation`;
  - in `MarkdownTextView.mouseDown`, a click on a task marker toggles it (pointing-hand cursor over markers) and any other click just places the caret;
  - Find (⌘F) and Find & Replace (⌥⌘F) commands drive `NSTextFinder` (`usesFindBar`, incremental search).

**Uses**
- NSTextView's undo-aware edit path: one undo step per command.
- `NSTextFinder`: native find and replace bar with no custom UI.

**Verify**
- Table-driven core tests for every transform:
  - with and without a selection;
  - unbolding text that is already bold;
  - multi-line headings and task items;
  - numbered-list increments and nested indentation;
  - Return on an empty `- [ ]` removes the marker.
- Each shortcut works, and one ⌘Z reverts it.
- Clicking `[ ]` toggles it and the file updates after autosave. Clicking elsewhere on the line just moves the caret.
- Replace All of `foo` → `bar` in the 5,000-line fixture is a single undo step with no stall.

### Phase 9 — Tags
**Builds**
- **Core `Frontmatter.settingTags(_:in:) -> TextEdit`:**
  - creates frontmatter if it is missing;
  - preserves every other key, comment and the existing list style byte-for-byte;
  - removing the last tag removes `tags:`, and removes the block if it becomes empty.
- **Core `LibraryIndex`:** tag counts.
- **App:**
  - a Tags section in the sidebar with counts; selecting a tag filters the list;
  - Add Tag… uses the palette as a picker over existing tags plus "Create ‘x’";
  - Remove Tag…;
  - both edit **through the editor buffer**, so they are undoable and autosaved;
  - a new note created while a tag is selected gets that tag, so it doesn't vanish from the filtered list.

**Uses**
- Nothing new. A hand-written frontmatter reader and writer for `tags` only, instead of a YAML library: a full YAML round-trip would reformat the user's other keys.

**Verify**
- Core tests: adding a tag to a note without frontmatter, with a flow list and with a block list; removing the last tag; other keys byte-identical.
- In a git-tracked fixture, `git diff` after adding a tag shows only the tags line.
- A tag added in vim appears in the sidebar within 1 s. A tag whose last use is removed disappears.

### Phase 10 — Search and task progress
**Builds**
- **Core `NoteSearch`:**
  - `localizedStandardContains` over title and body;
  - title hits first, then by mtime;
  - runs on an index snapshot off-main.
- **Core `TaskCounter`:** a fence-aware line scan stored in `NoteSummary`.
- **App:**
  - `.searchable` in the toolbar, debounced 150 ms, cancelling the previous search and scoped by Q6;
  - a Search Notes command (⇧⌘F) focuses the field;
  - rows show "3/5" with a small progress ring when a note has tasks.

**Uses**
- `localizedStandardContains`: Finder-style case-, diacritic- and locale-aware matching.

**Verify**
- In the 1,000-note fixture, the search signpost is under 50 ms, and holding a key in the search field doesn't stutter.
- `ozet` finds `Özet`.
- Title hits rank above body hits.
- Tasks inside code fences aren't counted (core test).
- Progress updates within about 1 s of toggling a task.

### Phase 11 — Preview
**Builds**
- **Core `HTMLRenderer`:** strips frontmatter, then runs swift-markdown's `HTMLFormatter`. That formatter already renders GFM tables, strikethrough, task checkboxes and `class="language-x"` on code, which highlight.js reads.
- **Core `TaskToggle.edit(togglingTaskNumber:in:)`:** the nth checkbox in document order, from the same parse.
- **App `PreviewView`, the page:**
  - WKWebView loads bundled `preview.html` once (`loadFileURL(_:allowingReadAccessTo:)`);
  - content is pushed with `callAsyncJavaScript("render(html)", arguments:)`, which passes the HTML as an argument and needs no escaping;
  - vendored, pinned highlight.js 11.x with light and dark themes via `prefers-color-scheme`;
  - a **Content-Security-Policy that allows only bundled scripts**, because `HTMLFormatter` passes raw HTML through;
  - non-persistent data store.
- **App `PreviewView`, behavior:**
  - checkbox clicks post the checkbox index to a message handler, which applies the edit to the editor buffer (undoable), and the preview re-renders;
  - link clicks are cancelled and opened with `NSWorkspace`;
  - re-renders are debounced on edits;
  - Toggle Preview (⌥⌘P; layout per Q4) keeps an approximate proportional scroll position.

**Uses**
- WebKit `WKWebView`: fixed decision.
- highlight.js: fixed decision, vendored so the preview works offline.

**Verify**
- Core test: for every fixture, the number of rendered checkboxes equals `TaskToggle`'s count. Frontmatter is absent from the HTML.
- Toggling preview on the 5,000-line note takes under 300 ms.
- Swift, Python, C, JS and Bash code blocks are highlighted.
- A checkbox click updates the editor and the file, and the scroll position is kept.
- `<script>alert(1)</script>` and `<img src=x onerror=alert(1)>` in a note do nothing.
- Links open in the default browser.
- The preview works with Wi-Fi off and follows dark mode.

### Phase 12 — Shortcut settings
**Builds**
- **Core `ShortcutMap`:** default shortcuts from `CommandID` plus user overrides. It detects conflicts and refuses to assign a shortcut that system-reserved or other commands already use.
- **App:**
  - a `Settings` scene with a Shortcuts pane: each command, its current shortcut, a recorder field and Reset;
  - overrides persisted in UserDefaults;
  - menus, palette hints and the alternate-shortcut monitor all read from the map.

**Uses**
- SwiftUI `Settings` scene: the standard ⌘, window.
- `NSEvent` local monitor for recording: captures the key and modifiers.

**Verify**
- Core tests: override, reset, conflict detection, and display strings.
- Rebinding Bold to ⌃⌘B updates the menu and palette hint immediately and survives relaunch.
- Assigning a shortcut that's already in use shows the conflict and keeps the old binding.

### Phase 13 — Hardening and docs
**Builds**
- A performance audit of the three budgets with Instruments, with the numbers recorded in ARCHITECTURE.md.
- **Liquid Glass and HIG pass:**
  - glass only on the toolbar, sidebar, palette and banner;
  - the editor is solid with a readable line length (about 70ch, centered);
  - animations use `.snappy` at 0.2 s or less and respect Reduce Motion.
- Accessibility: VoiceOver labels for rows (title, snippet, progress), sidebar counts and palette items.
- Edge states: no library; empty notebook; a non-UTF-8 file is listed but opens read-only with a message.
- Final README and ARCHITECTURE.md: layers, both data flows, adding a command, extension points.

**Verify**
- All three performance budgets are met and recorded.
- `grep -rE "NSVisualEffectView|Material\b" DocType/` finds no custom blur.
- The core-purity grep is still clean.
- No Swift file is over ~300 lines without a reason.
- Your friend builds a fresh clone using only the README.
- Reduce Transparency and Increase Contrast both render correctly.
- VoiceOver can move through sidebar → list → editor.

---

## 6. Open questions (each blocks only the phase noted; until answered, the placeholder default applies)

1. **Note title (Phase 1/5).** Should the title come from the filename, the first `# heading`, or a `title:` frontmatter key? *Default: filename.* Then what you see is the file in Finder, git and MCP, and rename is just a file rename.
-> ANSWER: filename
2. **Frontmatter in the editor (Phase 6).** Should it be visible and dimmed, or hidden behind a tag bar? *Default: visible and dimmed* (plain text, no hidden state).
-> ANSWER: hidden behind a tag bar
3. **Shortcuts (Phase 4/8).** ⌘K is "Add Link" in Notes, Pages and Mail, so with the palette on ⌘K, Link moves to ⇧⌘K. Proposed set:

   | Command | Shortcut | Command | Shortcut |
   |---|---|---|---|
   | Command Palette | ⌘K, ⇧⌘P | Bold / Italic | ⌘B / ⌘I |
   | New Note / New Notebook | ⌘N / ⇧⌘N | Inline Code | ⌘E (shadows "Use Selection for Find") |
   | Rename Note / Move Note… | ⇧⌘R / ⇧⌘M | Link | ⇧⌘K |
   | Move Note to Trash | ⌘⌫ | Heading 1–3 / Body Text | ⌥⌘1–3 / ⌥⌘0 |
   | Find / Find & Replace | ⌘F / ⌥⌘F | Task Item | ⇧⌘L (as in Apple Notes) |
   | Search All Notes | ⇧⌘F | Toggle Preview | ⌥⌘P |
ANSWER: Proposed set is good. But you should be able to change (these) shortcuts in the settings/configuration.
4. **Preview layout (Phase 11).** Should the preview replace the editor (a toggle) or sit beside it? *Default: replace.* Four columns are cramped on a laptop.
-> ANSWER: Replace.
5. **Nested notebooks (Phase 1).** Should the sidebar show the full folder tree, or only top-level folders? *Default: full tree, and selecting a notebook includes its subfolders.*
-> Full tree, and selecting a notebook includes it subfolders.
6. **Search scope (Phase 10).** Should search cover the current sidebar selection, or always the whole library? *Default: current selection* (choose All Notes to search everything).
-> Current selection (choose All Notes to search everything)
7. **Inkdrop migration.** Is an importer needed for the MVP, or will you use Inkdrop's Markdown export plus a one-off script? *Default: not in the MVP.*
-> Not in the MVP.
8. **Toolchain (Phase 0).** Do both of you use Xcode 27? `swift-tools-version: 6.4` fails on Xcode 26. *Default: lower it to 6.2*, which works with both, unless you need 6.4 features.
-> We both use Xcode 27.

## 7. Pieces worth writing yourselves

These are small (about 5–15 lines), they set behavior, and writing them is the quickest way to learn the codebase. Each gets a prepared stub with a `TODO` when we reach its phase:
- `FuzzyMatch.score` (Phase 4): how the palette ranks matches.
- The conflict-banner policy in `EditorController` (Phase 3): what "Keep Mine" and "Reload" do exactly.
- `ListContinuation`'s empty-item rule (Phase 8): end the list, outdent, or keep the marker.
- Snippet extraction rules in `NoteSummary` (Phase 1): what counts as the first meaningful text.

-> My answer to this section (7.): For the MVP, write a first version of these four yourself, choosing whatever makes most sense based on common conventions in editors like this. For each one, add a short comment block at the top of the code explaining what it does, why you chose it, and what alternatives you considered, and add unit tests that describe the chosen behavior. I'll review them after the MVP and change anything I don't like myself.

One fixed rule for the conflict banner: no option may ever lose text. Whichever version gets discarded is saved first (e.g. as a backup or `.conflict` file next to the note).

## 8. Known risks and how each phase catches them

- **TextKit 2 attribute styling.** Phase 6's checks (styles past the edited range appear immediately, IME works, no TextKit 1 fallback) verify the `willProcessEditing` approach early. The fallback is applying styles in `textDidChange` inside `textContentStorage.performEditingTransaction`.
- **Per-block parsing is approximate** in rare cases (lazy continuations across blank lines). The preview, which parses the whole document, is the exact rendering. Tests pin the cases we do support.
- **FSEvents bursts during `git checkout`.** Handled by batching at 0.3 s latency and publishing one snapshot per batch, and verified in Phase 3.
- **swift-markdown is pre-1.0.** It is pinned `.upToNextMinor`, so upgrades are deliberate.

## 9. Overall verification

After every phase:
- `xcodebuild -project DocType.xcodeproj -scheme DocType build` succeeds and the app launches;
- `cd DocTypeCore && swift test` passes;
- the phase's checks above are run by hand on the fixtures from `Scripts/make-fixtures.swift`.

The three performance budgets are measured first in Phases 2, 6 and 10 and re-audited in Phase 13:
- launch to an editable note in under 1 s with 1,000 notes;
- no file I/O on the main thread;
- smooth typing in a 5,000-line note.
