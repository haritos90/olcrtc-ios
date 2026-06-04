#!/usr/bin/env bash
#
# Build the app for a device WITHOUT code signing and wrap it into an unsigned
# `olcrtc-ios-unsigned.ipa` for sideloading (AltStore / Sideloadly re-sign it
# with the end user's Apple ID). Single source of truth for the .ipa, used both
# locally and by .github/workflows/release.yml.
#
# Requires the full Xcode (the iOS SDK) and an existing App/Mobile.xcframework
# (run scripts/fetch-framework.sh or scripts/build-framework.sh first).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -d App/Mobile.xcframework ]; then
  echo "error: App/Mobile.xcframework is missing — run scripts/fetch-framework.sh or scripts/build-framework.sh first" >&2
  exit 1
fi

# Regenerate the project if it isn't there (needs xcodegen on PATH).
[ -d olcrtc-ios.xcodeproj ] || xcodegen generate --spec project.yml

echo "note: building olcrtc-ios for device (Release, unsigned) ..."
xcodebuild \
  -project olcrtc-ios.xcodeproj \
  -scheme olcrtc-ios \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP="build/Build/Products/Release-iphoneos/olcrtc-ios.app"
if [ ! -d "$APP" ]; then
  echo "error: build did not produce $APP" >&2
  exit 1
fi

# An .ipa is just a zip with a Payload/ folder containing the .app.
rm -rf Payload olcrtc-ios-unsigned.ipa
mkdir Payload
cp -R "$APP" Payload/
zip -qr olcrtc-ios-unsigned.ipa Payload
rm -rf Payload

echo "done:  $ROOT/olcrtc-ios-unsigned.ipa"
