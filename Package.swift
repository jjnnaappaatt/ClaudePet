// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudePet",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure-Swift data layer — no AppKit/SwiftUI, fully unit-testable.
        .target(
            name: "ClaudePetCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The SwiftUI + AppKit app.
        .executableTarget(
            name: "ClaudePet",
            dependencies: ["ClaudePetCore"],
            exclude: ["Supporting/Info.plist", "Supporting/ClaudePet.entitlements"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudePetCoreTests",
            dependencies: ["ClaudePetCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
