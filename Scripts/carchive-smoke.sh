#!/usr/bin/env bash
# Build the c-archive for the host arch and run the standalone C probe against the
# real control plane. Proves the boundary (export symbols, header match, callback
# round-trip, string ownership) without SwiftPM or the Swift binding. Needs network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${TMPDIR:-/tmp}/tnk-carchive-smoke-build"
mkdir -p "$BUILD"

echo "[smoke] building host c-archive…"
( cd "$ROOT/Go" && CGO_ENABLED=1 go build -buildmode=c-archive -o "$BUILD/libtailnetcore.a" ./capi )

echo "[smoke] linking probe…"
clang -o "$BUILD/smoke" "$ROOT/CAPI/smoke/smoke.c" \
  -I"$ROOT/CAPI/include" "$BUILD/libtailnetcore.a" \
  -framework CoreFoundation -framework Security -lresolv

STATE_DIR="$BUILD/state-$$"
mkdir -p "$STATE_DIR"
trap 'rm -rf "$STATE_DIR"' EXIT

echo "[smoke] running probe…"
"$BUILD/smoke" "$STATE_DIR"
