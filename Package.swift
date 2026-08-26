// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClaudeSwitch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ClaudeSwitchCore", targets: ["ClaudeSwitchCore"]),
        .executable(name: "ClaudeSwitch", targets: ["ClaudeSwitch"])
    ],
    targets: [
        .target(
            name: "ClaudeSwitchCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "ClaudeSwitch",
            dependencies: ["ClaudeSwitchCore"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "ClaudeSwitchCoreTests",
            dependencies: ["ClaudeSwitchCore"]
        )
    ]
)
