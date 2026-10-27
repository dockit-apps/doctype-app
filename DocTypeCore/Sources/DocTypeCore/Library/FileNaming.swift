// Rules for naming note files: new notes, conflict copies; invalid names in Phase 5.

import Foundation

public enum FileNaming {
    /// `Uni/Graphs.md` → `Uni/Graphs (conflict 2026-10-27 135210).md`, adding ` 2`, ` 3`, …
    /// if that name is taken. The copy is an ordinary note on purpose: it shows up
    /// in the note list, so a conflict can't go unnoticed.
    static func conflictCopyPath(
        for path: String, in folder: String, date: Date, exists: (String) -> Bool
    ) -> String {
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let stamp = date.formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian)
        ))
        let base = "\(title) (conflict \(stamp))"
        var name = "\(base).md"
        var counter = 2
        while exists(join(folder, name)) {
            name = "\(base) \(counter).md"
            counter += 1
        }
        return join(folder, name)
    }

    /// `Untitled.md`, or `Untitled 2.md`, `Untitled 3.md`, … if taken, inside `folder`.
    static func availableNotePath(title: String, in folder: String, exists: (String) -> Bool) -> String {
        var name = "\(title).md"
        var counter = 2
        while exists(join(folder, name)) {
            name = "\(title) \(counter).md"
            counter += 1
        }
        return join(folder, name)
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }
}
