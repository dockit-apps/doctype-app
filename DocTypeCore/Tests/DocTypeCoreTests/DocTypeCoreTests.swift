// Smoke test proving the package builds and links.

import Testing
@testable import DocTypeCore

@Test func subsystemMatchesBundleIdentifier() {
    #expect(DocTypeCore.subsystem == "io.github.dockit-apps.doctype")
}
