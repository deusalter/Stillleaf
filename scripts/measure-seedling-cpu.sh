#!/bin/bash
# Idle CPU of the empty-state seedling, for before/after comparisons.
# Hosts the real empty state in a parked, focus-free window (BackgroundUI), so run it only
# when the Mac is free. Usage: scripts/measure-seedling-cpu.sh [binary] [seconds] [runs]
# Expect "window visible=true"; a false reading means the window was occluded or the
# screen is locked, which makes the seedling (correctly) stop and the number meaningless.
set -euo pipefail
cd "$(dirname "$0")/.."
BINARY="${1:-${BOOKSPRESENCE_BUILD_DIR:-.build/local}/BooksPresence}"
SECONDS_TO_SAMPLE="${2:-21}"
RUNS="${3:-3}"
for _ in $(seq "$RUNS"); do
  "$BINARY" --measure-seedling "$SECONDS_TO_SAMPLE" | tail -2
done
