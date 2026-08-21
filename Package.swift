// swift-tools-version: 6.0

import PackageDescription

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
        .target(
            name: "MacAgentCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ],
            path: "Sources/MacAgentCore"
        ),
        .executableTarget(
            name: "MacAgent",
            dependencies: ["MacAgentCore"],
            path: "Sources/MacAgent",
            resources: [
                .process("Resources")
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
