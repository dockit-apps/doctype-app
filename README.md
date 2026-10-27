# DocType

A native macOS markdown note-taking app. Notes are plain `.md` files in a folder you choose: notebooks are subfolders, tags live in YAML frontmatter, and changes made outside the app (git, other editors) show up automatically.

Status: early MVP development, see [docs/PLAN.md](docs/PLAN.md).

## Requirements

- macOS 26 or later
- Xcode 27 (Swift 6.4 toolchain)

## Build and run

1. Open `DocType.xcodeproj` in Xcode.
2. Select the **DocType** scheme and press ⌘R.

From the command line:

```bash
xcodebuild -project DocType.xcodeproj -scheme DocType -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/DocType.app
```

## Test

All logic lives in the `DocTypeCore` package and is unit-tested with Swift Testing:

```bash
cd DocTypeCore && swift test
```

## Project layout

- `DocType/`: the macOS app (SwiftUI + AppKit). Only views and the glue between views and core.
- `DocTypeCore/`: a local Swift package with the document model, library, markdown styling and commands. It never imports SwiftUI or AppKit.
- `docs/PLAN.md`: the MVP plan, phase by phase.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together.
