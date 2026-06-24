#!/usr/bin/env bash
# Build Vendor/TailnetCore.xcframework from Go/ via gomobile bind.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/TailnetCore.xcframework"
GO_DIR="$ROOT/Go"
TARGETS="${TAILNET_BIND_TARGETS:-ios,iossimulator,macos}"

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

if [[ -d "$OUT" && "${FORCE_REBUILD:-}" != "1" ]]; then
  echo "TailnetCore.xcframework present (set FORCE_REBUILD=1 to rebuild)"
  exit 0
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go not on PATH; install a pinned Go toolchain (see mise.toml / go.mod)" >&2
  exit 1
fi

if ! command -v gomobile >/dev/null 2>&1; then
  echo "error: gomobile not on PATH; install golang.org/x/mobile/cmd/gomobile and run 'gomobile init'" >&2
  exit 1
fi

log "Go: $(go version)"
log "gomobile: $(command -v gomobile)"
log "Target platforms: $TARGETS"
log "Output: $OUT"
log ""
log "TailnetCore rebuild compiles tailscale.com via gomobile."
log "First build after a tailscale upgrade often takes 15–40 minutes."
log "gomobile may go silent for several minutes at a time — that is normal."
log "Device-only rebuild (faster): TAILNET_BIND_TARGETS=ios FORCE_REBUILD=1 $0"
log ""

cd "$GO_DIR"

log "go mod tidy…"
go mod tidy

log "Starting gomobile bind -v (progress + long silent compile phases expected)…"

heartbeat() {
  while true; do
    sleep 60
    log "still compiling TailnetCore… (not stuck — gomobile is linking tailscale)"
  done
}
heartbeat &
heartbeat_pid=$!
trap 'kill "$heartbeat_pid" 2>/dev/null || true' EXIT

gomobile bind -v -target="$TARGETS" -o "$OUT" ./bridge

# gomobile emits `-init` as nullable, which conflicts with NSObject's nonnull init in Swift.
find "$OUT" -name 'Bridge.objc.h' -print0 | while IFS= read -r -d '' header; do
  perl -i -0pe 's/\n\/\*\*\n \* NewBridge constructs a tailnet bridge instance\.\n \*\/\n- \(nullable instancetype\)init;//g' "$header"
done

kill "$heartbeat_pid" 2>/dev/null || true
trap - EXIT

log "TailnetCore.xcframework installed at $OUT"
