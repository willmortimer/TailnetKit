#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_DIR="$ROOT/Go"

if ! command -v gomobile >/dev/null 2>&1; then
  echo "error: gomobile not on PATH; run: mise install" >&2
  exit 1
fi

# gomobile version needs a module context; check from the Go module dir.
if (cd "$GO_DIR" && gomobile version >/dev/null 2>&1); then
  echo "gomobile already initialized"
  exit 0
fi

echo "Running gomobile init (one-time; downloads mobile toolchain assets)..."
gomobile init
echo "gomobile init complete"
