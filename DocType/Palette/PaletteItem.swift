// What the palette shows: a list of items to filter and pick from.
// Used for commands, and later as a picker (notebooks, tags).

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
}
