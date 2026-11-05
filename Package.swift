// swift-tools-version: 5.10
//
// QDVC Case Manager for macOS — a native app that supports allocation
// supervisors in allocating cases to a pool of analysts. The workspace is a
// folder of plain YAML and CSV files (see docs/FILE_FORMAT.md), designed to
// be tracked with Git.
//
// No package dependencies, so building never downloads anything, and the
// app never touches the network (docs/MAINTENANCE.md §Offline).
//
// Build:   swift build            (or open this folder in Xcode)
// Test:    swift test
// Bundle:  scripts/build-app.sh   (ad-hoc signed .app, no Apple account needed)

import PackageDescription

var products: [Product] = [
    .library(name: "CaseCore", targets: ["CaseCore"]),
]
var targets: [Target] = [
    // Pure model layer: Foundation only, no AppKit/SwiftUI, unit-testable.
    .target(name: "CaseCore"),
    .testTarget(
        name: "CaseCoreTests",
        dependencies: ["CaseCore"]
    ),
]

#if os(macOS)
// The SwiftUI/AppKit front-end. Declared on macOS only, so the core and its
// tests also build with a Linux Swift toolchain (docs/MAINTENANCE.md).
products.insert(.executable(name: "QDVCCaseManager", targets: ["QDVCCaseManager"]), at: 0)
targets.insert(.executableTarget(name: "QDVCCaseManager", dependencies: ["CaseCore"]), at: 1)
#endif

let package = Package(
    name: "QDVCCaseManager",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
