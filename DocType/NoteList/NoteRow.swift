// One row in the note list: title, date, a two-line snippet, and task progress
// ("3/5" with a ring) when the note has tasks.

import DocTypeCore
import SwiftUI

struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if note.tasks.total > 0 {
                    TaskProgressView(progress: note.tasks)
                }
            }
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
        // Read as one: "Graphs, 3 of 5 tasks done, edited 28 October 2026, <snippet>".
        // All in the label: list cells don't pass a separate value on to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription)
    }

    private var spokenDescription: String {
        var parts = [note.title]
        if note.tasks.total > 0 { parts.append("\(note.tasks.done) of \(note.tasks.total) tasks done") }
        parts.append("edited \(note.modified.formatted(date: .long, time: .omitted))")
        if !note.snippet.isEmpty { parts.append(note.snippet) }
        return parts.joined(separator: ", ")
    }
}

/// "3/5" next to a small ring that fills as tasks are checked; green when all are done.
private struct TaskProgressView: View {
    let progress: TaskProgress
    /// `.increased` in a selected row, where an accent-colored ring would vanish.
    @Environment(\.backgroundProminence) private var prominence

    private var ringColor: Color {
        if prominence == .increased { return .primary }
        return progress.done == progress.total ? .green : .accentColor
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(progress.done)/\(progress.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(progress.done) / CGFloat(progress.total))
                    .stroke(ringColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 10, height: 10)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.done) of \(progress.total) tasks done")
    }
}
