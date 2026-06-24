// swift-tools-version: 6.0
import PackageDescription

// TailnetKit — a typed Swift wrapper over Tailscale's tsnet, packaged for Apple platforms.
//
// Initial extraction from iGhost (faithful move; the Core/Relay/Testing/UI/SSH module
// split described in ARCHITECTURE.md happens during the API redesign). For now:
//   - TailnetKit          : pure-Swift models, lifecycle, in-memory backend (no binary)
//   - TailnetKitEmbedded  : Go-backed tsnet backend (links TailnetCore.xcframework)
//
// The TailnetCore.xcframework is a build artifact (gitignored). Build it with
// `Scripts/build-xcframework.sh` (requires Go + gomobile), or, for binary distribution,
// it will be fetched as a checksummed binaryTarget from a release.

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
        // Pure-Swift core: models, lifecycle, protocols, in-memory backend. No binary dependency.
        .target(
            name: "TailnetKit",
            path: "Sources/TailnetKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),

        // Embedded tsnet backend, backed by the gomobile-generated XCFramework.
        .target(
            name: "TailnetKitEmbedded",
            dependencies: [
                "TailnetKit",
                "TailnetCore",
            ],
            path: "Sources/TailnetKitEmbedded",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),

        // gomobile-generated tsnet binary. Local path during bring-up; a checksummed
        // release URL is the target for binary distribution (ROADMAP Phase 4).
        .binaryTarget(
            name: "TailnetCore",
            path: "Vendor/TailnetCore.xcframework"
        ),
    ]
)
