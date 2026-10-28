// When another program changes the open note on disk: reload it, or, with
// unsaved edits, show the conflict banner (ExternalChangePolicy decides). No
// choice loses text: the version given up is saved as a conflict copy first.

import AppKit
import DocTypeCore

extension EditorController {
    /// Called when the open note may have changed on disk.
    func noteChangedOnDisk() async {
        guard let path, let library else { return }
        guard let disk = try? await library.readNote(path) else {
            await noteRemovedFromDisk()
            return
        }
        guard path == self.path else { return }  // switched notes while reading
        let diskText = disk.text
        switch ExternalChangePolicy.action(
            diskText: diskText, lastSyncedText: lastSyncedText,
            hasUnsavedEdits: isDirty, conflictPending: pendingDiskText != nil
        ) {
        case .ignore:
            break
        case .reload:
            let note = await prepare(disk, path: path)
            guard path == self.path else { return }
            if isDirty {
                // You started typing while the new version was being prepared.
                autosaveTask?.cancel()
                pendingDiskText = diskText
            } else {
                show(note, keepingPosition: true)
            }
        case .showConflict:
            autosaveTask?.cancel()
            pendingDiskText = diskText
        }
    }

    /// The open note was deleted or moved away by another program. Unsaved edits
    /// are kept as a conflict copy; then the editor closes.
    private func noteRemovedFromDisk() async {
        if let path, let library, isDirty || pendingDiskText != nil {
            do {
                try await library.saveConflictCopy(of: path, text: currentText)
            } catch {
                onError("Couldn't keep your edits to “\(path)”: \(error.localizedDescription)")
                return  // keep the text in the editor rather than lose it
            }
        }
        isDirty = false
        pendingDiskText = nil
        await close()
    }

    /// Applies the banner choice: first the conflict copy, then the final text.
    func resolveConflict(_ choice: ExternalChangePolicy.Choice) async {
        guard let diskText = pendingDiskText, let path, let library else { return }
        // Read-only while resolving, so nothing typed during the saves can be lost.
        textView.isEditable = false
        defer { textView.isEditable = !isReadOnly }
        let resolution = ExternalChangePolicy.resolve(choice, editorText: currentText, diskText: diskText)
        do {
            try await library.saveConflictCopy(of: path, text: resolution.copyText)
        } catch {
            onError("Couldn't save a conflict copy of “\(path)”: \(error.localizedDescription)")
            return  // banner stays; nothing has been discarded
        }
        pendingDiskText = nil
        switch choice {
        case .keepMine:
            lastSyncedText = diskText
            isDirty = true
            await save()
        case .useDiskVersion:
            show(await prepare(NoteText(text: resolution.finalText, isUTF8: true), path: path), keepingPosition: true)
        }
    }
}
