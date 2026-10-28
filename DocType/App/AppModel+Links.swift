// ⌘-clicking a link in the editor: notes open in DocType, everything else
// (web pages, mail, files next to the note) opens with the system.

import AppKit
import DocTypeCore

extension AppModel {
    func openLink(_ destination: String) {
        guard let notePath = editor.path, let libraryURL,
              let target = LinkTarget.resolve(destination, fromNote: notePath, libraryRoot: libraryURL) else { return }
        switch target {
        case .note(let path):
            // Match the index's spelling: links often differ in case from the file name.
            if let match = index.notes.keys.first(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
                selectedNotePath = match
            } else {
                errorMessage = "There's no note “\(path)” in this library."
            }
        case .external(let url):
            if !NSWorkspace.shared.open(url) {
                errorMessage = "Couldn't open “\(destination)”."
            }
        }
    }
}
