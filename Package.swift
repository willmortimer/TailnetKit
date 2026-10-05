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
        url: "https://github.com/willmortimer/TailnetKit/releases/download/v0.3.1/TailnetCore.xcframework.zip",
        checksum: "13ce2efd6ff73533111184d3b39c74e4ec5afc83f0018d0a9b4afdb3159bddc5"
    )

let package = Package(
    name: "TailnetKit",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TailnetKitCore", targets: ["TailnetKitCore"]),
        .library(name: "TailnetKitEmbedded", targets: ["TailnetKitEmbedded"]),
        .library(name: "TailnetKitTesting", targets: ["TailnetKitTesting"]),
        .library(name: "TailnetKitNIO", targets: ["TailnetKitNIO"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
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
        // SwiftNIO Channel over an already-dialed TailnetConnection. No sockets.
        .target(
            name: "TailnetKitNIO",
            dependencies: [
                "TailnetKitCore",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Sources/TailnetKitNIO",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TailnetKitTests",
            dependencies: [
                "TailnetKitCore",
                "TailnetKitTesting",
                "TailnetKitNIO",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
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
