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
rm -rf "$OUT/Stillleaf.xcresult"
xcodebuild "${COMMON[@]}" -destination "platform=iOS Simulator,id=$DEVICE" -resultBundlePath "$OUT/Stillleaf.xcresult" \
  test-without-building
