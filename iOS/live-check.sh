#!/bin/bash
# Check the iPhone app's own code against a real Spark Swapper.
#
#   ./live-check.sh
#
# Starts the Swapper itself (github.com/gnubyte/DGX-Spark-Swapper, in its demo mode: its real web service,
# sign-in, app tokens, connection codes, status and switch jobs over HTTPS with its own certificate — no GPU and
# no model behind it) and a stand-in model server that, like vLLM, refuses more than two pictures a request.
# Then runs iOS/VisionTests in the simulator: add the box by address and login and by connection code, chat
# with too many pictures and with a PDF, and ask for a model switch.
#
#   SWAPPER_DIR=<checkout>   use this Swapper checkout instead of cloning one into build/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
LIVE="$ROOT/build/live"
SWAPPER_PORT=18999
MODEL_PORT=18080
mkdir -p "$LIVE"

SWAPPER_DIR="${SWAPPER_DIR:-$ROOT/build/DGX-Spark-Swapper}"
if [ ! -f "$SWAPPER_DIR/swapper/app.py" ]; then
  echo "==> fetching the Spark Swapper"
  git clone --quiet --depth 1 https://github.com/gnubyte/DGX-Spark-Swapper "$SWAPPER_DIR"
fi
echo "==> Spark Swapper $(cat "$SWAPPER_DIR/swapper/VERSION" 2>/dev/null || echo '?') at $(git -C "$SWAPPER_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"

# The Swapper makes its own certificate on a box; here it is made up front, where the Swapper looks for it, so a
# machine whose openssl differs from the box's still starts it.
mkdir -p "$LIVE/conf" "$LIVE/state"
if [ ! -f "$LIVE/conf/tls.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout "$LIVE/conf/tls.key" -out "$LIVE/conf/tls.crt" \
      -subj "/CN=Spark Swapper (live check)" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>"$LIVE/openssl.log" \
    || openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout "$LIVE/conf/tls.key" -out "$LIVE/conf/tls.crt" \
      -subj "/CN=Spark Swapper (live check)" 2>>"$LIVE/openssl.log" \
    || { echo "could not make a certificate:" >&2; cat "$LIVE/openssl.log" >&2; exit 1; }
fi

pids=()
cleanup() { for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

SWAPPER_DEMO=1 SWAPPER_CONF="$LIVE/conf" SWAPPER_STATE="$LIVE/state" SWAPPER_BIND=127.0.0.1 SWAPPER_PORT=$SWAPPER_PORT \
  python3 "$SWAPPER_DIR/swapper/app.py" > "$LIVE/swapper.log" 2>&1 &
pids+=($!)
python3 "$ROOT/tools/fake-model-server.py" $MODEL_PORT 2 > "$LIVE/model-server.log" 2>&1 &
pids+=($!)

for _ in $(seq 1 40); do
  if curl -sk --max-time 2 "https://127.0.0.1:$SWAPPER_PORT/api/session" | grep -q '"version"' \
     && curl -s --max-time 2 "http://127.0.0.1:$MODEL_PORT/v1/models" | grep -q stand-in; then ready=1; break; fi
  sleep 0.5
done
[ "${ready:-0}" = "1" ] || { echo "the servers did not come up" >&2; cat "$LIVE/swapper.log" "$LIVE/model-server.log" >&2; exit 1; }
echo "==> $(head -n 2 "$LIVE/swapper.log" | tail -n 1)"

command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate --spec project.yml --quiet
DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted((r for r in devices if "iOS" in r), reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        break
')"
[ -n "$DEVICE" ] || { echo "no iPhone simulator is installed" >&2; exit 1; }

echo "==> running the live tests in the simulator"
set +e
TEST_RUNNER_VISION_SWAPPER_URL="https://127.0.0.1:$SWAPPER_PORT" \
TEST_RUNNER_VISION_MODEL_API="http://127.0.0.1:$MODEL_PORT/v1" \
xcodebuild test -project Vision.xcodeproj -scheme Vision \
  -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath "$ROOT/build/sim" \
  > "$LIVE/test.log" 2>&1
status=$?
set -e
grep -E "LIVE:|Test Case .*(passed|failed)|error:|XCTAssert|Executed [0-9]+ tests|\*\* TEST" "$LIVE/test.log" | sed 's/^/    /' || true
echo "==> what the model server was sent"
grep -E "picture\(s\) in the request|POST" "$LIVE/model-server.log" | sed 's/^/    /' || true
echo "==> what the Swapper saw"
grep -E "POST|/api/connect|/api/status" "$LIVE/swapper.log" | awk '{ $1=""; print "   " $0 }' | sort | uniq -c | sort -rn | head -n 12 || true

if [ $status -ne 0 ]; then
  echo "the live tests failed (full log: $LIVE/test.log)" >&2
  tail -n 60 "$LIVE/test.log" >&2
  exit 1
fi
if grep -Eq "Test Case .* skipped|with [1-9][0-9]* tests? skipped|Executed 0 tests" "$LIVE/test.log" \
   || ! grep -q "LIVE: switch to" "$LIVE/test.log" || ! grep -q "LIVE: signed in to" "$LIVE/test.log"; then
  echo "the live tests did not run against the servers (skipped)" >&2
  exit 1
fi
echo "==> the iPhone app's code works against Spark Swapper $(cat "$SWAPPER_DIR/swapper/VERSION" 2>/dev/null || echo '')"
