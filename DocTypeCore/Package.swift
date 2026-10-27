// swift-tools-version: 6.4
// DocTypeCore: the UI-free heart of DocType (notes, library, markdown, commands).
// It must never import SwiftUI or AppKit, so a future MCP server can use it headless.

import PackageDescription

let package = Package(
    name: "DocTypeCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DocTypeCore", targets: ["DocTypeCore"]),
    ],
    dependencies: [
        // Pre-1.0, so pin to the minor version and upgrade deliberately.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .target(
            name: "DocTypeCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "DocTypeCoreTests",
            dependencies: ["DocTypeCore"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ]
)
