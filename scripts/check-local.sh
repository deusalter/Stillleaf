#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-local.sh
OUT="${BOOKSPRESENCE_BUILD_DIR:-.build/local}"
SWIFTC="${BOOKSPRESENCE_SWIFTC:-$(xcrun --find swiftc)}"
"$SWIFTC" -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0" Sources/BooksPresence/Theme.swift scripts/theme-contrast-smoke.swift -o "$OUT/theme-contrast-smoke"
"$OUT/theme-contrast-smoke"
for suite in audiobook progress-coverage history-atlas core discord calendar books manual-pages session-history goals reading-dates reader-domain reader-resources epub-import epub-removal reader-state reader-state-transfer; do
  "$SWIFTC" -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0" -I "$OUT" -I Sources/CSQLite -L "$OUT" -lBooksCore -lBooksPlatform "scripts/$suite-smoke.swift" -o "$OUT/$suite-smoke" -Xlinker -rpath -Xlinker @executable_path
  "$OUT/$suite-smoke"
done
"$SWIFTC" -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0" -I "$OUT" -I Sources/CSQLite -L "$OUT" -lBooksCore Sources/BooksPresence/BookMergeResolver.swift Sources/BooksPresence/LibraryProgressLabel.swift scripts/library-progress-smoke.swift -o "$OUT/library-progress-smoke" -Xlinker -rpath -Xlinker @executable_path
"$OUT/library-progress-smoke"
"$OUT/BooksPresence" --self-test-ui
"$OUT/BooksPresence" --self-test-audio "$OUT/audiobook-review"
"$OUT/books-diagnostic"
