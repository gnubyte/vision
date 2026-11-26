#!/bin/bash
# Run Vision in the iOS simulator on its demo data and make sure every screen comes up and stays up.
#
#   ./simulator-smoke.sh [output folder]      (default: build/screens)
#
# Builds for the simulator, boots an iPhone, opens the app on each demo screen (`-VisionDemo YES
# -VisionDemoScreen <name>`: a made-up box and chat, no network, nothing kept), checks the app is still running a
# few seconds later, and saves a screenshot of each. With SMOKE_PRINT=1 it also prints a small copy of every
# screenshot as base64 between "SHOT <name>" and "END SHOT" lines, for looking at a CI run from its log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
OUT="${1:-$ROOT/build/screens}"
BUNDLE="com.503cm.vision.ios"
SCREENS="chats chat boxes box history settings"

command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate --spec project.yml --quiet

echo "==> building for the simulator"
xcodebuild -project Vision.xcodeproj -scheme Vision -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$ROOT/build/sim" build \
  | { command -v xcbeautify >/dev/null && xcbeautify --quiet || cat; }
APP="$ROOT/build/sim/Build/Products/Debug-iphonesimulator/Vision.app"
[ -d "$APP" ] || { echo "no simulator build: $APP" >&2; exit 1; }

DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
# The newest iOS runtime that has an iPhone.
for runtime in sorted((r for r in devices if "iOS" in r), reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        break
')"
[ -n "$DEVICE" ] || { echo "no iPhone simulator is installed" >&2; exit 1; }
echo "==> simulator $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"

mkdir -p "$OUT"
for screen in $SCREENS; do
  xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
  launched="$(xcrun simctl launch "$DEVICE" "$BUNDLE" -VisionDemo YES -VisionDemoScreen "$screen")"
  pid="${launched##*: }"
  sleep 7
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Vision exited on the '$screen' screen" >&2
    xcrun simctl spawn "$DEVICE" log show --last 1m --predicate 'process == "Vision"' --style compact 2>/dev/null | tail -n 40 >&2 || true
    exit 1
  fi
  xcrun simctl io "$DEVICE" screenshot "$OUT/$screen.png" >/dev/null 2>&1
  echo "ok: $screen (pid $pid)"
  if [ "${SMOKE_PRINT:-0}" = "1" ]; then
    sips -Z 560 -s format jpeg -s formatOptions 38 "$OUT/$screen.png" --out "$OUT/$screen.small.jpg" >/dev/null
    echo "SHOT $screen"
    base64 -i "$OUT/$screen.small.jpg" | fold -w 160
    echo "END SHOT"
    rm -f "$OUT/$screen.small.jpg"
  fi
done
xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
echo "==> every screen came up; screenshots in $OUT"
