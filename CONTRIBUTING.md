# Contributing

The API isn't stable yet — it's still being shaped as the implementation is
extracted from its original app. Open an issue before starting any large change.

## Build

    mise install                 # Go toolchain
    mise run build-carchive      # builds Vendor/TailnetCore.xcframework (slow)
    swift test

`TailnetKitCore` and `TailnetKitTesting` build without the XCFramework.
`TailnetKitEmbedded` needs `Vendor/TailnetCore.xcframework`, compiled from `Go/capi`
by the build script.

By default the package fetches the published `TailnetCore.xcframework` from the
matching GitHub release. To build against a locally-compiled framework instead, set
`TAILNETKIT_LOCAL_BINARY=1` (the mise tasks already do).

The framework exposes a flat C ABI (`Go/capi`, `CAPI/include/tailnetcore.h`) built
with `go build -buildmode=c-archive`. A macOS-only build is fast and host-testable:

    TAILNET_CARCHIVE_TARGETS=macos mise run build-carchive
    mise run carchive-smoke      # links the C probe against the boundary (needs network)
