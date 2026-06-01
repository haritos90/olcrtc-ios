#!/usr/bin/env bash
# #253: Download a prebuilt App/Mobile.xcframework from GitHub Releases — the fast
# path that avoids building locally (./scripts/build-framework.sh is the fallback).
# The release workflow (.github/workflows/release.yml) attaches Mobile.xcframework.zip
# to every tagged release.
#
# Usage:
#   ./scripts/fetch-framework.sh                          # latest release
#   ./scripts/fetch-framework.sh v1.2.210                 # a specific tag
#   GH_REPO=owner/olcrtc-ios ./scripts/fetch-framework.sh # outside a clone
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/App"
ASSET="Mobile.xcframework.zip"
TAG="${1:-}"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: GitHub CLI (gh) not found. Install it ('brew install gh') or build from source: ./scripts/build-framework.sh" >&2
  exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
  echo "error: 'unzip' not found." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ -n "$TAG" ]; then
  echo "note: downloading $ASSET from release $TAG ..."
  gh release download "$TAG" --pattern "$ASSET" --dir "$tmp"
else
  echo "note: downloading $ASSET from the latest release ..."
  gh release download --pattern "$ASSET" --dir "$tmp"
fi

echo "note: unpacking into $APP/Mobile.xcframework ..."
rm -rf "$APP/Mobile.xcframework"
unzip -q "$tmp/$ASSET" -d "$APP"

echo "done:  $APP/Mobile.xcframework"
echo "next:  xcodegen generate --spec project.yml"
