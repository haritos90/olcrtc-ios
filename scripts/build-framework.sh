#!/usr/bin/env bash
# #253: Build App/Mobile.xcframework from the olcrtc-upstream submodule with gomobile.
#
# Single source of truth for the framework build — humans, CI (ci.yml) and the
# release workflow (release.yml) all call this. Prefer the prebuilt download
# (./scripts/fetch-framework.sh) unless you are building against a moved submodule
# pin or changing olcrtc-upstream/mobile/mobile.go.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/olcrtc-upstream"
OUT="$ROOT/App/Mobile.xcframework"

if [ ! -f "$UPSTREAM/mobile/mobile.go" ]; then
  echo "error: $UPSTREAM/mobile/mobile.go missing — run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go toolchain not found. Install Go (the version pinned in olcrtc-upstream/go.mod), e.g. 'brew install go'." >&2
  exit 1
fi

# gomobile installs into $(go env GOPATH)/bin, which isn't on PATH by default.
export PATH="$PATH:$(go env GOPATH)/bin"
if ! command -v gomobile >/dev/null 2>&1; then
  echo "note: gomobile not found — installing golang.org/x/mobile/cmd/gomobile@latest ..."
  go install golang.org/x/mobile/cmd/gomobile@latest
fi
gomobile init

echo "note: gomobile bind -target=ios -> $OUT (~5 min on first run) ..."
cd "$UPSTREAM"
gomobile bind -target=ios -o "$OUT" ./mobile

echo "done:  $OUT"
echo "next:  xcodegen generate --spec project.yml   # so Xcode picks up the framework"
