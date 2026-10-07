#!/bin/bash
# Live CPU measurements for the garden. Needs a real window, so run it only when the Mac is free
# (the dev-tool windows are parked in the bottom-right corner and never take focus).
#
#   scripts/measure-garden-cpu.sh [build-dir]        # default .build/local
#
# 1. Idle: opens the synthetic dashboard on each section, waits for growth to settle, and
#    samples the process's CPU time over 10 s. Target for a grown, breathing garden: <= 2%.
# 2. Scroll: STILLLEAF_MEASURE_GARDEN=1 opens a Library of 80 books, reports idle and
#    scrolling CPU, and whether the window counted as visible (breathing only runs when it is).
#    STILLLEAF_MEASURE_GARDEN=off repeats it with the garden switched off, to isolate its share.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-${BOOKSPRESENCE_BUILD_DIR:-.build/local}}/BooksPresence"
SETTLE="${SETTLE:-45}"
WINDOW="${WINDOW:-10}"

idle_cpu() {
  local section=$1 appearance=$2
  "$BIN" --preview-library --preview-section "$section" --preview-appearance "$appearance" >/dev/null 2>&1 &
  local pid=$!
  sleep "$SETTLE"
  local before after
  before=$(ps -o time= -p "$pid" | tr -d ' ' | awk -F'[:.]' '{ printf "%.2f", $1*60+$2+$3/100 }')
  sleep "$WINDOW"
  after=$(ps -o time= -p "$pid" | tr -d ' ' | awk -F'[:.]' '{ printf "%.2f", $1*60+$2+$3/100 }')
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "$section/$appearance idle: $(echo "$after $before $WINDOW" | awk '{ printf "%.2f%% CPU over %ss", ($1-$2)/$3*100, $3 }')"
}

for section in today library settings; do
  for appearance in dark light; do idle_cpu "$section" "$appearance"; done
done
for mode in 1 off; do
  echo "scroll harness, garden=$mode:"
  STILLLEAF_MEASURE_GARDEN=$mode "$BIN" --self-test-ui 2>&1 | grep -a "garden-measure"
done
