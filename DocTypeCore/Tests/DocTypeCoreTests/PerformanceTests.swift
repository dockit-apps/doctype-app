// Local performance checks against a generated fixture library.
// Skipped unless DOCTYPE_FIXTURES points at output of Scripts/make-fixtures.swift:
//   DOCTYPE_FIXTURES=~/DocTypeFixtures swift test --filter PerformanceTests
// Debug builds are unoptimized, so these numbers are an upper bound.

import Foundation
import Testing
import DocTypeCore

private let fixturesPath = ProcessInfo.processInfo.environment["DOCTYPE_FIXTURES"]

@Suite(.enabled(if: fixturesPath != nil, "Set DOCTYPE_FIXTURES to run"))
struct PerformanceTests {
    @Test func scanningTheFixtureLibraryStaysUnderBudget() async throws {
        let library = Library(root: URL(fileURLWithPath: fixturesPath!))
        let clock = ContinuousClock()

        let elapsed = try await clock.measure { try await library.scan() }

        let count = await library.index.notes.count
        print("Scanned \(count) notes in \(elapsed)")
        #expect(count >= 1_000)
        #expect(elapsed < .milliseconds(500))
    }
}
