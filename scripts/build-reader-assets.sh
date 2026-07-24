#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-.build/local}"
# The renderer is its own npm package, so this build never installs Electron or test browsers.
RENDERER=Reader/desktop/reader
if [[ ! -d "$RENDERER/node_modules" ]]; then
  npm --prefix "$RENDERER" ci
fi
npm --prefix "$RENDERER" run build
mkdir -p "$OUT/Reader"
# Replace only this generated build asset directory, never installed resources.
find "$OUT/Reader" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R "$RENDERER/dist/." "$OUT/Reader/"
