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

_Filled in as the editor (Phases 2 and 6) and the command system (Phase 4) land._

## Adding a command

_Filled in in Phase 4._

## Planned extension points

- **MCP server.** A future `doctype-mcp` executable target in `DocTypeCore/Package.swift`, using the same `Library` actor as the app.
- **DocShelf.** A `doctype://open?path=…` URL scheme mapped to the app's "open note" action. Lookups go through a small `LookupProvider` protocol, with DocShelf (`docshelf://search?q=…`) as its first implementation.
- **Commands.** Every user action is a named command in one registry. Menus, shortcuts, the palette and later MCP tools all call the same core functions.
