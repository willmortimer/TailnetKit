// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TailnetKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TailnetKitCore", targets: ["TailnetKitCore"]),
        .library(name: "TailnetKitEmbedded", targets: ["TailnetKitEmbedded"]),
        .library(name: "TailnetKitTesting", targets: ["TailnetKitTesting"]),
    ],
    targets: [
        // Models, lifecycle, client, errors. No binary dependency.
        .target(
            name: "TailnetKitCore",
            path: "Sources/TailnetKitCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // In-memory backend for tests and previews.
        .target(
            name: "TailnetKitTesting",
            dependencies: ["TailnetKitCore"],
            path: "Sources/TailnetKitTesting",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // tsnet backend backed by the gomobile-built XCFramework.
        .target(
            name: "TailnetKitEmbedded",
            dependencies: ["TailnetKitCore", "TailnetCore"],
            path: "Sources/TailnetKitEmbedded",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Built from Go/ by Scripts/build-xcframework.sh; not committed.
        .binaryTarget(
            name: "TailnetCore",
            path: "Vendor/TailnetCore.xcframework"
        ),
        .testTarget(
            name: "TailnetKitTests",
            dependencies: ["TailnetKitCore", "TailnetKitTesting"],
            path: "Tests/TailnetKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Live smoke tests against a real control plane; skipped unless TAILNET_INTEGRATION=1.
        .testTarget(
            name: "TailnetKitIntegrationTests",
            dependencies: ["TailnetKitCore", "TailnetKitEmbedded"],
            path: "Tests/TailnetKitIntegrationTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
