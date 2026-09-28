#!/bin/bash
# Compare the optimized daily algorithms with a supplied pre-change Git revision.
# Requires scripts/build-local.sh first. Uses synthetic data only.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="${1:?Pass the pre-change Git revision}"
OUT="${BOOKSPRESENCE_BUILD_DIR:-.build/local}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
python3 - "$BASE" "$TMP" <<'PY'
import pathlib, subprocess, sys
base, folder = sys.argv[1:]
for file, name in [('ReadingStatistics.swift', 'ReadingStatistics'), ('PageTurns.swift', 'PageStatistics')]:
    source = subprocess.check_output(['git', 'show', f'{base}:Sources/BooksCore/{file}'], text=True)
    if name == 'PageStatistics':
        source = source[source.index('public enum PageStatistics'):]
    source = 'import Foundation\n@testable import BooksCore\n' + source.replace(name, 'Legacy' + name)
    pathlib.Path(folder, file).write_text(source)
pathlib.Path(folder, 'main.swift').write_text(pathlib.Path('scripts/history-performance-smoke.swift').read_text())
PY
"${BOOKSPRESENCE_SWIFTC:-$(xcrun --find swiftc)}" -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0" -O -D LEGACY_COMPARISON -I "$OUT" -I Sources/CSQLite -L "$OUT" -lBooksCore "$TMP"/*.swift -o "$OUT/history-performance-comparison" -Xlinker -rpath -Xlinker @executable_path
"$OUT/history-performance-comparison"
