// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TailnetKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TailnetKit", targets: ["TailnetKit"]),
        .library(name: "TailnetKitEmbedded", targets: ["TailnetKitEmbedded"]),
    ],
    targets: [
        // Models, lifecycle, in-memory backend. No binary dependency.
        .target(
            name: "TailnetKit",
            path: "Sources/TailnetKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // tsnet backend backed by the gomobile-built XCFramework.
        .target(
            name: "TailnetKitEmbedded",
            dependencies: ["TailnetKit", "TailnetCore"],
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
            dependencies: ["TailnetKit"],
            path: "Tests/TailnetKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
