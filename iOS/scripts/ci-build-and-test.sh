#!/bin/bash
# Builds the iOS app for the simulator and for devices (unsigned), then runs the XCTest bundle on the
# newest available iPhone simulator and captures every screen there and on an iPad. Needs full Xcode;
# used by .github/workflows/ios.yml.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${STILLLEAF_IOS_OUT:-$PWD/.build/ios}"
mkdir -p "$OUT"

# The same renderer build the Mac package uses, prepared once for every xcodebuild below.
export STILLLEAF_READER_ASSETS="$OUT/reader-assets"
scripts/build-reader-assets.sh "$STILLLEAF_READER_ASSETS"
iOS/scripts/generate-project.sh

# The newest runtime's simulator of a family ("iPhone" or "iPad"), preferring names that contain the
# second argument when one is given: prints its UDID.
pick_simulator() {
  xcrun simctl list devices available --json | python3 -c '
import json, sys
family, preferred = sys.argv[1], sys.argv[2]
runtimes = json.load(sys.stdin)["devices"]
def version(key):
    tail = key.rsplit(".", 1)[-1]
    return tuple(int(p) for p in tail.split("-")[1:] if p.isdigit()) if tail.startswith("iOS") else ()
best = None
for key, devices in runtimes.items():
    for device in devices:
        if version(key) and device["name"].startswith(family) and device.get("isAvailable", True):
            candidate = (version(key), bool(preferred) and preferred in device["name"], device["name"], device["udid"])
            best = max(best, candidate) if best else candidate
if not best:
    sys.exit("No available %s simulator" % family)
version_text = ".".join(str(part) for part in best[0])
print(best[3])
print("Simulator: %s (iOS %s)" % (best[2], version_text), file=sys.stderr)
' "$1" "${2:-}"
}
DEVICE=$(pick_simulator iPhone)

COMMON=(-project iOS/Stillleaf.xcodeproj -scheme Stillleaf -derivedDataPath "$OUT/derived" CODE_SIGNING_ALLOWED=NO)

# Device build: arm64, Release, no signing. Catches device-only compile and packaging errors.
xcodebuild "${COMMON[@]}" -quiet -configuration Release -destination 'generic/platform=iOS' build

xcodebuild "${COMMON[@]}" -quiet -destination "platform=iOS Simulator,id=$DEVICE" build-for-testing

# ScreenshotTests asks for a picture of each screen by writing <name>.request into this folder, which the
# simulator shares with the host. Answer each with a real simulator screenshot until the tests finish.
SHOTS="${STILLLEAF_SCREENSHOTS:-/tmp/stillleaf-ios-screenshots}"
rm -rf "$SHOTS" "$OUT/screenshots"
mkdir -p "$SHOTS" "$OUT/screenshots"

# Boots a simulator, runs the given tests on it while answering screenshot requests, and returns the test status.
run_tests() {
  local device="$1" bundle="$2"; shift 2
  rm -f "$SHOTS/.stop"
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b >/dev/null 2>&1 || true
  xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true
  (
    while [ ! -e "$SHOTS/.stop" ]; do
      for request in "$SHOTS"/*.request; do
        [ -e "$request" ] || continue
        name="$(basename "$request" .request)"
        if xcrun simctl io "$device" screenshot --type=png "$SHOTS/.$name.png" >/dev/null 2>&1; then mv "$SHOTS/.$name.png" "$SHOTS/$name.png"; fi
        rm -f "$request"
      done
      sleep 0.2
    done
  ) &
  local capture=$! status=0
  rm -rf "$bundle"
  xcodebuild "${COMMON[@]}" -destination "platform=iOS Simulator,id=$device" -resultBundlePath "$bundle" \
    -parallel-testing-enabled NO test-without-building "$@" || status=$?
  touch "$SHOTS/.stop"
  wait "$capture" 2>/dev/null || true
  cp "$SHOTS"/*.png "$OUT/screenshots/" 2>/dev/null || true
  xcrun simctl shutdown "$device" 2>/dev/null || true
  return "$status"
}

STATUS=0
run_tests "$DEVICE" "$OUT/Stillleaf.xcresult" || STATUS=$?

# The same screens on an iPad, whose pictures are named ipad-<name>. Only the capture runs there; the
# other tests have already run on the iPhone. A runner with no iPad simulator skips this.
if TABLET=$(pick_simulator iPad 11-inch); then
  run_tests "$TABLET" "$OUT/Stillleaf-iPad.xcresult" -only-testing:StillleafTests/ScreenshotTests || STATUS=$?
fi
echo "Screenshots: $(ls "$OUT/screenshots" | wc -l | tr -d ' ') in $OUT/screenshots"
exit "$STATUS"
