// What the palette shows: a list of items to filter and pick from.
// Used for commands, and as a picker (notebooks, tags).

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    /// Shown on the right, e.g. the command's shortcut.
    let detail: String?
    let action: () -> Void
}

struct Palette {
    var placeholder: String
    var items: [PaletteItem]
    /// An extra item made from what's typed, listed after the matches (e.g. "Create tag ‘x’").
    var itemForQuery: ((String) -> PaletteItem?)? = nil
}
