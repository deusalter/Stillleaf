#!/bin/bash
# Builds the iOS app for the simulator and for devices (unsigned), then runs the XCTest
# bundle on the newest available iPhone simulator. Needs full Xcode; used by .github/workflows/ios.yml.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${STILLLEAF_IOS_OUT:-$PWD/.build/ios}"
mkdir -p "$OUT"

# The same renderer build the Mac package uses, prepared once for every xcodebuild below.
export STILLLEAF_READER_ASSETS="$OUT/reader-assets"
scripts/build-reader-assets.sh "$STILLLEAF_READER_ASSETS"
iOS/scripts/generate-project.sh

DEVICE=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
runtimes = json.load(sys.stdin)["devices"]
def version(key):
    tail = key.rsplit(".", 1)[-1]
    return tuple(int(p) for p in tail.split("-")[1:] if p.isdigit()) if tail.startswith("iOS") else ()
best = None
for key, devices in runtimes.items():
    for device in devices:
        if version(key) and device["name"].startswith("iPhone") and device.get("isAvailable", True):
            candidate = (version(key), device["name"], device["udid"])
            best = max(best, candidate) if best else candidate
if not best:
    sys.exit("No available iPhone simulator")
version_text = ".".join(str(part) for part in best[0])
print(best[2])
print("Simulator: %s (iOS %s)" % (best[1], version_text), file=sys.stderr)
')

COMMON=(-project iOS/Stillleaf.xcodeproj -scheme Stillleaf -derivedDataPath "$OUT/derived" CODE_SIGNING_ALLOWED=NO)

# Device build: arm64, Release, no signing. Catches device-only compile and packaging errors.
xcodebuild "${COMMON[@]}" -quiet -configuration Release -destination 'generic/platform=iOS' build

xcodebuild "${COMMON[@]}" -quiet -destination "platform=iOS Simulator,id=$DEVICE" build-for-testing

# ScreenshotTests asks for a picture of each screen by writing <name>.request into this folder, which the
# simulator shares with the host. Answer each with a real simulator screenshot until the tests finish.
SHOTS="${STILLLEAF_SCREENSHOTS:-/tmp/stillleaf-ios-screenshots}"
rm -rf "$SHOTS" "$OUT/screenshots"
mkdir -p "$SHOTS"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true
(
  while [ ! -e "$SHOTS/.stop" ]; do
    for request in "$SHOTS"/*.request; do
      [ -e "$request" ] || continue
      name="$(basename "$request" .request)"
      if xcrun simctl io "$DEVICE" screenshot --type=png "$SHOTS/.$name.png" >/dev/null 2>&1; then mv "$SHOTS/.$name.png" "$SHOTS/$name.png"; fi
      rm -f "$request"
    done
    sleep 0.2
  done
) &
CAPTURE=$!

rm -rf "$OUT/Stillleaf.xcresult"
STATUS=0
xcodebuild "${COMMON[@]}" -destination "platform=iOS Simulator,id=$DEVICE" -resultBundlePath "$OUT/Stillleaf.xcresult" \
  -parallel-testing-enabled NO test-without-building || STATUS=$?
touch "$SHOTS/.stop"
wait "$CAPTURE" 2>/dev/null || true
mkdir -p "$OUT/screenshots"
cp "$SHOTS"/*.png "$OUT/screenshots/" 2>/dev/null || true
echo "Screenshots: $(ls "$OUT/screenshots" | wc -l | tr -d ' ') in $OUT/screenshots"
exit "$STATUS"
