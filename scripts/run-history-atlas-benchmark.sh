#!/bin/sh
set -eu
cd "$(git rev-parse --show-toplevel)"
swift build -c release --target BooksCore
bin=$(swift build -c release --show-bin-path)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -O -parse-as-library -I "$bin/Modules" -I Sources/CSQLite \
    scripts/history-atlas-benchmark.swift "$bin"/BooksCore.build/*.o -lsqlite3 \
    -o "$scratch/history-atlas-benchmark"
"$scratch/history-atlas-benchmark" "${1:-100000}"
