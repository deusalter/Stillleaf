#!/bin/bash
# Generates iOS/Stillleaf.xcodeproj from iOS/project.yml with a pinned, checksum-verified XcodeGen.
# Generating needs no Xcode; building does. The generated project is not committed.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.46.0
SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
TOOLS="../.build/tools/xcodegen-$VERSION"
XCODEGEN="$TOOLS/xcodegen/bin/xcodegen"
if [[ ! -x "$XCODEGEN" ]]; then
  mkdir -p "$TOOLS"
  curl -fsSL -o "$TOOLS/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
  echo "$SHA256  $TOOLS/xcodegen.zip" | shasum -a 256 -c - >/dev/null
  unzip -q -o "$TOOLS/xcodegen.zip" -d "$TOOLS"
fi
"$XCODEGEN" generate --spec project.yml --quiet
echo "Generated iOS/Stillleaf.xcodeproj"
