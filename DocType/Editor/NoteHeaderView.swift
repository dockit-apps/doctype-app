// Above the editor: the note's title (its filename, editable to rename it) and
// a read-only row of its tags. Tag editing arrives in Phase 9.

import SwiftUI

struct NoteHeaderView: View {
    @Environment(AppModel.self) private var model
    let path: String

    @State private var draft = ""
    @FocusState private var isTitleFocused: Bool

    private var title: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .bold))
                .focused($isTitleFocused)
                // Return moves into the text; the rename happens when the field loses focus.
                .onSubmit { model.editor.focusText() }
                .onExitCommand {
                    draft = title
                    model.editor.focusText()
                }
                .onChange(of: isTitleFocused) { _, focused in
                    if !focused { commit() }
                }

            if !model.editor.tags.isEmpty {
                TagRow(tags: model.editor.tags)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { draft = title }
        .onChange(of: path) { draft = title }
        .onChange(of: model.titleFocusRequest) { isTitleFocused = true }
    }

    private func commit() {
        guard draft.trimmingCharacters(in: .whitespaces) != title else {
            draft = title
            return
        }
        Task {
            if !(await model.renameOpenNote(to: draft)) { draft = title }
        }
    }
}

/// Tags as small capsules, e.g. `#exam  #week-3`.
struct TagRow: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
    }
}
