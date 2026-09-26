#!/bin/bash
# Rebuild all identity assets from the approved native vector geometry.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc Sources/BooksPresence/Pageleaf.swift scripts/generate-pageleaf.swift -o .build/generate-pageleaf
.build/generate-pageleaf "$PWD"
iconutil -c icns .build/Pageleaf.iconset -o assets/BooksPresence.icns
