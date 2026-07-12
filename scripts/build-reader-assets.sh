#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-.build/local}"
if [[ ! -d Reader/desktop/node_modules ]]; then
  npm --prefix Reader/desktop ci
fi
npm --prefix Reader/desktop run build:reader
mkdir -p "$OUT/Reader"
# Replace only this generated build asset directory, never installed resources.
find "$OUT/Reader" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R Reader/desktop/reader/dist/. "$OUT/Reader/"
