// swift-tools-version: 6.0

import Foundation
import PackageDescription

/// Where scripts/fetch-cua-driver.sh puts cua-driver's library. Absolute, because the linker runs
/// from a directory of SwiftPM's choosing, and the same path is the run path a test or a
/// `swift run` finds the library on; a packaged app finds it in its own Frameworks folder instead.
let cuaDriverDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Vendor/cua-driver").path

let package = Package(
    name: "MacAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacAgent", targets: ["MacAgent"]),
        .library(name: "MacAgentCore", targets: ["MacAgentCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.5")
    ],
    targets: [
        // cua-driver, which Sonny drives other apps through, loaded into Sonny's own process
        // (founders, 2026-09-24). Run scripts/fetch-cua-driver.sh once before building.
        .systemLibrary(
            name: "CCuaDriver",
            path: "Sources/CCuaDriver"
        ),
        .target(
            name: "MacAgentCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                "CCuaDriver"
            ],
            path: "Sources/MacAgentCore",
            linkerSettings: [
                .unsafeFlags(["-L", cuaDriverDirectory, "-Xlinker", "-rpath", "-Xlinker", cuaDriverDirectory])
            ]
        ),
        .executableTarget(
            name: "MacAgent",
            dependencies: ["MacAgentCore"],
            path: "Sources/MacAgent",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // package-app.sh copies the library into the bundle's Frameworks folder.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // Test helpers both test targets need, in one copy (SONNY-172). A `.testTarget` rather than
        // a `.target` deliberately: these helpers declare a `Testing` `ConditionTrait`, and a plain
        // target is in the ordinary build graph, where `swift build` passes no `-Xswiftc -F
        // .../CommandLineTools/Library/Developer/Frameworks` and the file fails with `no such module
        // 'Testing'`. Measured, not assumed — the probe on this ticket built both shapes. A test
        // target gets `Testing` and `-enable-testing` for free and stays out of `swift build`.
        // It carries no tests of its own; SwiftPM raises no diagnostic for that.
        .testTarget(
            name: "MacAgentTestSupport",
            dependencies: ["MacAgentCore"],
            path: "Tests/MacAgentTestSupport"
        ),
        .testTarget(
            name: "MacAgentCoreTests",
            dependencies: ["MacAgentCore", "MacAgentTestSupport"],
            path: "Tests/MacAgentCoreTests"
        ),
        .testTarget(
            name: "MacAgentTests",
            dependencies: ["MacAgent", "MacAgentCore", "MacAgentTestSupport"],
            path: "Tests/MacAgentTests"
        )
    ]
)
