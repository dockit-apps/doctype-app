// One row in the note list: title, date and a two-line snippet.

import DocTypeCore
import SwiftUI

struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.headline)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.modified, format: .dateTime.day().month(.abbreviated).year())
                    .foregroundStyle(.secondary)
                Text(note.snippet)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
