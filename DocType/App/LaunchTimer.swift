// Measures the "launch to an editable note in under 1 s" budget: logs the time
// from process start to the first note being ready for typing, once per launch
// (in release builds too, so the audit measures what users run).

import Foundation
import os

enum LaunchTimer {
    private static var hasLogged = false

    static func logEditable() {
        guard !hasLogged, let start = processStartDate() else { return }
        hasLogged = true
        let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        Logger(subsystem: "io.github.dockit-apps.doctype", category: "launch")
            .notice("Launch to editable note: \(milliseconds) ms")
        #if DEBUG
        print("Launch to editable note: \(milliseconds) ms")
        #endif
    }

    private static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
