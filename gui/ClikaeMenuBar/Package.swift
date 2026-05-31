// swift-tools-version:5.9
// gui/ClikaeMenuBar — a macOS menu bar app for clikae.
//
// Built as a SwiftPM executable (no Xcode required — `swift build` works with
// the Command Line Tools). It is a menu-bar-only agent: it adds an NSStatusItem
// and treats the `clikae` CLI as the single source of truth, shelling out to it
// rather than reimplementing profile logic.

import PackageDescription

let package = Package(
    name: "ClikaeMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClikaeMenuBar",
            path: "Sources/ClikaeMenuBar"
        )
    ]
)
