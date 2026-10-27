// The floating glass palette: a search field over a fuzzy-filtered list.
// ↑/↓ move, Return runs, Escape or a click outside closes.

import DocTypeCore
import SwiftUI

struct CommandPaletteView: View {
    let palette: Palette
    let onChoose: (PaletteItem) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isFieldFocused: Bool

    private var results: [PaletteItem] {
        let matches = FuzzyMatch.rank(palette.items, by: query) { $0.title }
        guard let extra = palette.itemForQuery?(query) else { return matches }
        return matches + [extra]
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(palette.placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($isFieldFocused)
                .onSubmit { chooseSelected() }
                .onKeyPress(.upArrow) { moveSelection(by: -1) }
                .onKeyPress(.downArrow) { moveSelection(by: 1) }
                .onExitCommand(perform: onDismiss)

            if !results.isEmpty {
                Divider()
                list
            }
        }
        .frame(width: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onChange(of: query) { selectedIndex = 0 }
        .onAppear {
            // The editor (an AppKit view) still has focus at this point and would keep
            // it; ask again on the next turn of the run loop, once the palette is shown.
            isFieldFocused = true
            Task { isFieldFocused = true }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        // A real Button (not a tap gesture), so VoiceOver can activate rows.
                        Button { onChoose(item) } label: {
                            row(item, isSelected: index == selectedIndex)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedIndex) {
                if results.indices.contains(selectedIndex) { proxy.scrollTo(results[selectedIndex].id) }
            }
        }
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack {
            Text(item.title)
            Spacer()
            if let detail = item.detail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
        return .handled
    }

    private func chooseSelected() {
        if results.indices.contains(selectedIndex) { onChoose(results[selectedIndex]) }
    }
}
