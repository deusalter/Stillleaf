#!/bin/bash
# Direct compiler build for Macs whose Command Line Tools cannot run SwiftPM.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${BOOKSPRESENCE_BUILD_DIR:-.build/local}"
mkdir -p "$OUT"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="${BOOKSPRESENCE_SWIFTC:-$(xcrun --find swiftc)}"
# Packaged apps use this same build. Enable release optimization for the tracker and UI.
FLAGS=(-sdk "$SDK" -target "$(uname -m)-apple-macosx13.0" -I Sources/CSQLite -enable-testing -O)
"$SWIFTC" "${FLAGS[@]}" -emit-library -emit-module -module-name BooksCore Sources/BooksCore/*.swift -emit-module-path "$OUT/BooksCore.swiftmodule" -o "$OUT/libBooksCore.dylib" -Xlinker -install_name -Xlinker @rpath/libBooksCore.dylib
"$SWIFTC" "${FLAGS[@]}" -I "$OUT" -L "$OUT" -lBooksCore -emit-library -emit-module -module-name BooksPlatform Sources/BooksPlatform/*.swift -emit-module-path "$OUT/BooksPlatform.swiftmodule" -o "$OUT/libBooksPlatform.dylib" -Xlinker -install_name -Xlinker @rpath/libBooksPlatform.dylib
"$SWIFTC" "${FLAGS[@]}" -I "$OUT" -L "$OUT" -lBooksCore -lBooksPlatform Sources/BooksDiagnostic/main.swift -o "$OUT/books-diagnostic" -Xlinker -rpath -Xlinker @executable_path -Xlinker -rpath -Xlinker @executable_path/../Frameworks
if [[ "${1:-}" != "--diagnostic-only" ]]; then
  if [[ "${BOOKSPRESENCE_SKIP_READER_BUILD:-0}" != "1" ]]; then
    scripts/build-reader-assets.sh "$OUT"
  fi
  "$SWIFTC" "${FLAGS[@]}" -I "$OUT" -L "$OUT" -lBooksCore -lBooksPlatform -parse-as-library Sources/BooksPresence/*.swift -o "$OUT/BooksPresence" -Xlinker -rpath -Xlinker @executable_path -Xlinker -rpath -Xlinker @executable_path/../Frameworks
fi
printf 'Built into %s\n' "$OUT"
