// The Settings window (⌘,). One pane for now: Shortcuts, where each command's
// shortcut can be recorded, removed or reset (ShortcutSettings holds the logic).

import DocTypeCore
import SwiftUI

struct SettingsView: View {
    let shortcuts: ShortcutSettings

    var body: some View {
        TabView {
            ShortcutSettingsView(settings: shortcuts)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 600)
    }
}

struct ShortcutSettingsView: View {
    let settings: ShortcutSettings

    /// Menus in the order they appear in the menu bar.
    private let menus: [MenuName] = [.file, .edit, .view, .note, .format, .table]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(menus, id: \.self) { menu in
                    Section(menu.rawValue) {
                        ForEach(CommandID.allCases.filter { $0.info.menu == menu }, id: \.self) { command in
                            row(command)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            footer
        }
        .onDisappear { settings.stopRecording() }
    }

    private func row(_ command: CommandID) -> some View {
        let isRecording = settings.recording == command
        let current = settings.shortcuts(for: command).map(\.displayString).joined(separator: ", ")
        return HStack {
            Text(command.title)
            Spacer()
            Button {
                isRecording ? settings.stopRecording() : settings.startRecording(command)
            } label: {
                Text(isRecording ? "Type shortcut…" : current.isEmpty ? "None" : current)
                    .foregroundStyle(isRecording || current.isEmpty ? .secondary : .primary)
                    .frame(minWidth: 110)
            }
            .accessibilityLabel("Shortcut for \(command.title)")
            .accessibilityValue(current.isEmpty ? "None" : current)
            Button {
                settings.reset(command)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to \(command.info.defaultShortcuts.map(\.displayString).joined(separator: ", ").nonEmpty ?? "no shortcut")")
            .accessibilityLabel("Reset \(command.title)")
            .opacity(settings.map.isCustomized(command) ? 1 : 0)  // keeps the column lined up
            .disabled(!settings.map.isCustomized(command))
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if let message = settings.message, !message.isEmpty {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Click a shortcut, then press the new keys. Escape cancels; Delete removes it.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset All") { settings.resetAll() }
                .disabled(settings.map.overrides.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
