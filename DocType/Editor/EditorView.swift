// SwiftUI wrapper around the editor's scroll view. The controller keeps the same
// text view alive across note switches; this view only hosts it.

import AppKit
import SwiftUI

struct EditorView: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> NSScrollView {
        controller.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}
