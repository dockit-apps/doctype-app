// Floating glass banner shown when the open note changed on disk while you had
// unsaved edits. Either choice keeps the other version as a conflict copy.

import SwiftUI

struct ConflictBanner: View {
    let onKeepMine: () -> Void
    let onUseDiskVersion: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("This note changed on disk")
                    .font(.headline)
                Text("The version you don't keep is saved as a conflict copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Use Disk Version", action: onUseDiskVersion)
            // No keyboard shortcut on purpose: Return must keep typing in the editor.
            Button("Keep Mine", action: onKeepMine)
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}
