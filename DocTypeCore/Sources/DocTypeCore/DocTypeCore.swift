// Package-level constants shared by the app and (later) the MCP server.

import os

public enum DocTypeCore {
    /// Bundle identifier of the DocType app; also used as the os_log/signpost subsystem.
    public static let subsystem = "io.github.dockit-apps.doctype"

    /// Intervals show up under "Points of Interest" in Instruments.
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
