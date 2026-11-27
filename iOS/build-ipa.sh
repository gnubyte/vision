#!/bin/bash
# Build Vision for iPhone and package it as build/Vision.ipa.
#
#   ./build-ipa.sh            an unsigned IPA (for AltStore, Sideloadly or any re-signing tool)
#
# Needs Xcode 16+ and XcodeGen (brew install xcodegen). The IPA is not signed: iOS only installs signed apps, so
# either re-sign it with a sideloading tool (they sign with your own Apple ID), or open the project in Xcode,
# pick your team under Signing & Capabilities and run it on your phone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/Vision.xcarchive"

command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }

echo "==> generating Vision.xcodeproj"
xcodegen generate --spec project.yml --quiet

echo "==> archiving (Release, iOS device, unsigned)"
rm -rf "$BUILD"
mkdir -p "$BUILD"
xcodebuild -project Vision.xcodeproj -scheme Vision -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$BUILD/derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  archive | { command -v xcbeautify >/dev/null && xcbeautify --quiet || cat; }

APP="$ARCHIVE/Products/Applications/Vision.app"
[ -d "$APP" ] || { echo "no app in the archive: $APP" >&2; exit 1; }

echo "==> packaging Vision.ipa"
mkdir -p "$BUILD/Payload"
cp -R "$APP" "$BUILD/Payload/"
( cd "$BUILD" && zip -qry Vision.ipa Payload )
rm -rf "$BUILD/Payload"
ls -lh "$BUILD/Vision.ipa"
