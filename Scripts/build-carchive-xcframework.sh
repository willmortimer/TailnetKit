#!/usr/bin/env bash
# Build Vendor/TailnetCore.xcframework from Go/capi via `go build -buildmode=c-archive`.
# This replaces gomobile: it cross-compiles the C ABI per platform/arch, lipo-fuses the
# arches, and packages them with the hand-written headers into an xcframework.
#
# Targets: TAILNET_CARCHIVE_TARGETS (comma list of ios,iossimulator,tvos,tvossimulator,macos;
# default all). A macos-only build is fast and host-testable: TAILNET_CARCHIVE_TARGETS=macos
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_DIR="$ROOT/Go"
HEADERS="$ROOT/CAPI/include"
OUT="$ROOT/Vendor/TailnetCore.xcframework"
BUILD="$ROOT/.carchive-build"
TARGETS="${TAILNET_CARCHIVE_TARGETS:-ios,iossimulator,tvos,tvossimulator,macos}"

IOS_MIN=17.0
TVOS_MIN=17.0
MACOS_MIN=14.0
LIB=libtailnetcore.a

log() { echo "[$(date '+%H:%M:%S')] $*"; }
has_target() { [[ ",$TARGETS," == *",$1,"* ]]; }

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go not on PATH (see mise.toml)" >&2; exit 1
fi

# build_arch <out.a> <GOOS> <GOARCH> <sdk> <clang-target-triple>
build_arch() {
  local out="$1" goos="$2" goarch="$3" sdk="$4" triple="$5"
  local sysroot clang flags
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  clang="$(xcrun --sdk "$sdk" --find clang)"
  flags="-isysroot $sysroot -target $triple"
  mkdir -p "$(dirname "$out")"
  log "  $goos/$goarch ($triple)…"
  ( cd "$GO_DIR" && \
    GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=1 \
    CC="$clang" CGO_CFLAGS="$flags" CGO_LDFLAGS="$flags" \
    go build -buildmode=c-archive -o "$out" ./capi )
}

# make_framework <static-lib.a> <TailnetCore.framework dir>
# Packages a (possibly lipo-fused) static archive as a static framework. Frameworks
# carry their module map inside Modules/, so they don't collide in Xcode's shared
# include/ directory the way -library/-headers xcframeworks do.
make_framework() {
  local lib="$1" fw="$2"
  rm -rf "$fw"
  mkdir -p "$fw/Headers" "$fw/Modules"
  cp "$lib" "$fw/TailnetCore"
  cp "$HEADERS/tailnetcore.h" "$fw/Headers/tailnetcore.h"
  cat > "$fw/Modules/module.modulemap" <<'MM'
framework module TailnetCore {
    header "tailnetcore.h"
    export *
}
MM
  cat > "$fw/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>TailnetCore</string>
  <key>CFBundleIdentifier</key><string>com.tailnetkit.TailnetCore</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>TailnetCore</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PL
}

rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD"

log "Go: $(go version)"
log "Targets: $TARGETS"
log "c-archive builds recompile tailscale.com per arch; expect long, mostly silent phases."

heartbeat() { while true; do sleep 60; log "  still compiling… (not stuck)"; done; }
heartbeat & heartbeat_pid=$!
trap 'kill "$heartbeat_pid" 2>/dev/null || true' EXIT

XCARGS=()

if has_target ios; then
  log "Building iOS device slice"
  build_arch "$BUILD/ios-arm64/$LIB" ios arm64 iphoneos "arm64-apple-ios${IOS_MIN}"
  make_framework "$BUILD/ios-arm64/$LIB" "$BUILD/ios-arm64/fw/TailnetCore.framework"
  XCARGS+=(-framework "$BUILD/ios-arm64/fw/TailnetCore.framework")
fi

if has_target iossimulator; then
  log "Building iOS simulator slice (arm64 + x86_64)"
  build_arch "$BUILD/ios-sim-arm64/$LIB" ios arm64 iphonesimulator "arm64-apple-ios${IOS_MIN}-simulator"
  build_arch "$BUILD/ios-sim-amd64/$LIB" ios amd64 iphonesimulator "x86_64-apple-ios${IOS_MIN}-simulator"
  mkdir -p "$BUILD/ios-simulator"
  lipo -create "$BUILD/ios-sim-arm64/$LIB" "$BUILD/ios-sim-amd64/$LIB" -output "$BUILD/ios-simulator/$LIB"
  make_framework "$BUILD/ios-simulator/$LIB" "$BUILD/ios-simulator/fw/TailnetCore.framework"
  XCARGS+=(-framework "$BUILD/ios-simulator/fw/TailnetCore.framework")
fi

if has_target macos; then
  log "Building macOS slice (arm64 + x86_64)"
  build_arch "$BUILD/macos-arm64/$LIB" darwin arm64 macosx "arm64-apple-macos${MACOS_MIN}"
  build_arch "$BUILD/macos-amd64/$LIB" darwin amd64 macosx "x86_64-apple-macos${MACOS_MIN}"
  mkdir -p "$BUILD/macos"
  lipo -create "$BUILD/macos-arm64/$LIB" "$BUILD/macos-amd64/$LIB" -output "$BUILD/macos/$LIB"
  make_framework "$BUILD/macos/$LIB" "$BUILD/macos/fw/TailnetCore.framework"
  XCARGS+=(-framework "$BUILD/macos/fw/TailnetCore.framework")
fi

if has_target tvos; then
  log "Building tvOS device slice"
  build_arch "$BUILD/tvos-arm64/$LIB" ios arm64 appletvos "arm64-apple-tvos${TVOS_MIN}"
  make_framework "$BUILD/tvos-arm64/$LIB" "$BUILD/tvos-arm64/fw/TailnetCore.framework"
  XCARGS+=(-framework "$BUILD/tvos-arm64/fw/TailnetCore.framework")
fi

if has_target tvossimulator; then
  log "Building tvOS simulator slice (arm64 + x86_64)"
  build_arch "$BUILD/tvos-sim-arm64/$LIB" ios arm64 appletvsimulator "arm64-apple-tvos${TVOS_MIN}-simulator"
  build_arch "$BUILD/tvos-sim-amd64/$LIB" ios amd64 appletvsimulator "x86_64-apple-tvos${TVOS_MIN}-simulator"
  mkdir -p "$BUILD/tvos-simulator"
  lipo -create "$BUILD/tvos-sim-arm64/$LIB" "$BUILD/tvos-sim-amd64/$LIB" -output "$BUILD/tvos-simulator/$LIB"
  make_framework "$BUILD/tvos-simulator/$LIB" "$BUILD/tvos-simulator/fw/TailnetCore.framework"
  XCARGS+=(-framework "$BUILD/tvos-simulator/fw/TailnetCore.framework")
fi

kill "$heartbeat_pid" 2>/dev/null || true
trap - EXIT

if [[ ${#XCARGS[@]} -eq 0 ]]; then
  echo "error: no targets selected (TAILNET_CARCHIVE_TARGETS=$TARGETS)" >&2; exit 1
fi

log "Packaging xcframework"
xcodebuild -create-xcframework "${XCARGS[@]}" -output "$OUT" >/dev/null

log "TailnetCore.xcframework installed at $OUT"
