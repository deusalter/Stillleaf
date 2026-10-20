#!/bin/bash
# Compiles the platform-neutral iOS model, with the Mac presentation files it shares, against a
# macOS build of BooksCore/BooksPlatform and runs its smoke checks. Needs Command Line Tools only;
# the simulator build and XCTest suite run in .github/workflows/ios.yml.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${BOOKSPRESENCE_BUILD_DIR:-.build/local}"
if [[ "${1:-}" == "--rebuild" || ! -f "$OUT/libBooksPlatform.dylib" ]]; then
  scripts/build-local.sh --diagnostic-only
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="${BOOKSPRESENCE_SWIFTC:-$(xcrun --find swiftc)}"
TARGET="$(uname -m)-apple-macosx13.0"
LIBS="$(cd "$OUT" && pwd)"
source iOS/shared-sources.sh
"$SWIFTC" -parse-as-library -sdk "$SDK" -target "$TARGET" -I "$OUT" -I Sources/CSQLite -L "$OUT" -lBooksCore -lBooksPlatform \
  "${STILLLEAF_SHARED_SOURCES[@]}" iOS/Stillleaf/Model/*.swift iOS/StillleafTests/Support/SyntheticEPUB.swift iOS/scripts/model-smoke.swift \
  -o "$OUT/ios-model-smoke" -Xlinker -rpath -Xlinker "$LIBS"
SHELL_DIR=""
[[ -f "$OUT/Reader/index.html" ]] && SHELL_DIR="$OUT/Reader"
"$OUT/ios-model-smoke" ${SHELL_DIR:+"$SHELL_DIR"}
STILLLEAF_PORTABLE_ZIP=1 "$OUT/ios-model-smoke"
# Every hostile-archive case in the import suite, through the iOS (portable) ZIP reader.
"$SWIFTC" -sdk "$SDK" -target "$TARGET" -I "$OUT" -I Sources/CSQLite -L "$OUT" -lBooksCore -lBooksPlatform \
  scripts/epub-import-smoke.swift -o "$OUT/epub-import-smoke" -Xlinker -rpath -Xlinker "$LIBS"
STILLLEAF_PORTABLE_ZIP=1 "$OUT/epub-import-smoke"
