// Rules for naming notes and notebooks: valid names, free names, conflict copies.

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
    /// With `extension: nil` it names folders the same way.
    static func availablePath(name: String, extension: String?, in folder: String, exists: (String) -> Bool) -> String {
        let suffix = `extension`.map { ".\($0)" } ?? ""
        var candidate = "\(name)\(suffix)"
        var counter = 2
        while exists(join(folder, candidate)) {
            candidate = "\(name) \(counter)\(suffix)"
            counter += 1
        }
        return join(folder, candidate)
    }

    /// Trims a user-typed note or notebook name and checks it can be a file name
    /// that stays visible in Finder and works in git.
    public static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            throw LibraryError.invalidName("A name can't be empty.")
        }
        if name.contains("/") || name.contains(":") {
            throw LibraryError.invalidName("Names can't contain “/” or “:”.")
        }
        if name.hasPrefix(".") {
            throw LibraryError.invalidName("Names can't start with a dot; the file would be hidden.")
        }
        if name.utf8.count > 250 {
            throw LibraryError.invalidName("That name is too long.")
        }
        return name
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }
}
