#!/bin/bash
# Usage: scripts/preview-chrome-library.sh OUTPUT [BEFORE_SOURCE_DIRECTORY]
# The optional source snapshot produces the same fixtures before the fix.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${BOOKSPRESENCE_BUILD_DIR:-.build/local}"
DEST="${1:?Supply an output directory}"
SOURCE="${2:-Sources/BooksPresence}"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
cp "$SOURCE/"*.swift "$TEMP/"
sed -i '' 's/^@main$//' "$TEMP/BooksPresenceApp.swift"
# Expose only the initial hover state in the copied fixture sources.
sed -i '' 's/@State private var hovering = false/@State var hovering = false/' "$TEMP/LibraryView.swift"
# macOS 13 exposes Reduce Motion read-only. Inject the fixture value in the
# temporary card source, preserving the exact production animation branch.
python3 - "$TEMP/LibraryView.swift" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('@Environment(\\.accessibilityReduceMotion) private var reduceMotion',
    'private var reduceMotion: Bool { ChromeLibraryPreview.reducedMotion }'))
PYTHON
FLAGS=(-D CHROME_PREVIEW)
PREVIEW="$OUT/chrome-library-preview-after"
if [[ -n "${2:-}" ]]; then FLAGS+=(-D CHROME_BEFORE); PREVIEW="$OUT/chrome-library-preview-before"; fi
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0" \
  -I Sources/CSQLite -I "$OUT" -L "$OUT" -lBooksCore -lBooksPlatform -parse-as-library \
  "${FLAGS[@]}" "$TEMP/"*.swift scripts/chrome-library-preview.swift -o "$PREVIEW" \
  -Xlinker -rpath -Xlinker @executable_path
"$PREVIEW" "$DEST"
