# Contributing

The API isn't stable yet — it's still being shaped as the implementation is
extracted from its original app. Open an issue before starting any large change.

## Build

    mise install                 # Go + gomobile
    mise run gomobile-init       # one-time
    mise run build-xcframework   # builds Vendor/TailnetCore.xcframework (slow)
    swift test

The Swift `TailnetKit` target builds without the XCFramework. `TailnetKitEmbedded`
and the tests need `Vendor/TailnetCore.xcframework`, compiled from `Go/` by the
build script.
