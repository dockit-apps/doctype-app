// The Settings window (⌘,). One pane for now: Shortcuts, where each command's
// shortcut can be found by searching, then recorded, removed or reset
// (ShortcutSettings holds the logic).

import DocTypeCore
import AppKit
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
    @State private var query = ""

    /// Menus in the order they appear in the menu bar.
    private let menus: [MenuName] = [.file, .edit, .view, .note, .format, .table]

    var body: some View {
        VStack(spacing: 0) {
            searchField
            let shown = menus.map { menu in (menu, commands(in: menu)) }.filter { !$0.1.isEmpty }
            if shown.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)  // the field stays at the top
            } else {
                Form {
                    ForEach(shown, id: \.0) { menu, commands in
                        Section(menu.rawValue) {
                            ForEach(commands, id: \.self) { command in row(command) }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            footer
        }
        .onDisappear { settings.stopRecording() }
    }

    /// The menu's commands that match the search: by name, menu or current
    /// shortcut, ignoring case and accents ("bold", "table", "⌘B").
    private func commands(in menu: MenuName) -> [CommandID] {
        let words = query.split(separator: " ").map(String.init)
        return CommandID.allCases.filter { command in
            guard command.info.menu == menu else { return false }
            let shortcuts = settings.shortcuts(for: command).map(\.displayString).joined(separator: " ")
            let searchable = "\(command.title) \(menu.rawValue) \(shortcuts)"
            return words.allSatisfy { searchable.localizedStandardContains($0) }
        }
    }

    private var searchField: some View {
        SearchField(text: $query, prompt: "Search shortcuts")
            .accessibilityLabel("Search shortcuts")
            .padding(.horizontal, 20)
            .padding(.top, 14)
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

/// The native search field (rounded, clear button, Escape clears). It takes the
/// keyboard when the window opens, so typing searches right away, as in System Settings.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
