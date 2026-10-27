// Checking and unchecking a task: "[ ]" ↔ "[x]". Only the character inside the
// brackets changes, so the text keeps its length and the cursor stays put.

import Foundation

public enum TaskToggle {
    /// Toggles the task box that starts at `boxLocation` (its "["), or nil if
    /// there's no "[ ]", "[x]" or "[X]" there.
    public static func edit(togglingBoxAt boxLocation: Int, in text: NSString, selection: NSRange) -> TextEdit? {
        guard boxLocation >= 0, boxLocation + 3 <= text.length else { return nil }
        let box = text.substring(with: NSRange(location: boxLocation, length: 3))
        let replacement: String
        switch box {
        case "[ ]": replacement = "x"
        case "[x]", "[X]": replacement = " "
        default: return nil
        }
        return TextEdit(range: NSRange(location: boxLocation + 1, length: 1), replacement: replacement,
                        selectionAfter: selection)
    }
}
