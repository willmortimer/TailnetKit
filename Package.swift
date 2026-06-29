// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Consumers get the published xcframework by default. Contributors building the
// framework locally set TAILNETKIT_LOCAL_BINARY=1 to use Vendor/TailnetCore.xcframework
// (see Scripts/build-carchive-xcframework.sh). mise sets it for the local tasks.
let tailnetCoreBinary: Target = ProcessInfo.processInfo.environment["TAILNETKIT_LOCAL_BINARY"] != nil
    ? .binaryTarget(name: "TailnetCore", path: "Vendor/TailnetCore.xcframework")
    : .binaryTarget(
        name: "TailnetCore",
        url: "https://github.com/willmortimer/TailnetKit/releases/download/v0.1.1/TailnetCore.xcframework.zip",
        checksum: "e184ec2971bf5c075c362bd8aa0b95cb1a267a7ae71d0f613f221712224b7cf3"
    )

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
        // Published release by default; local build via TAILNETKIT_LOCAL_BINARY=1.
        tailnetCoreBinary,
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
