#!/bin/bash
# Cost of the living garden (new shoots, withering, wind, petals, fireflies).
#
#   scripts/measure-living-garden.sh [build-dir]            # frame budget only: headless, safe any time
#   scripts/measure-living-garden.sh --live [build-dir]     # also sample real idle CPU
#
# 1. Frame budget (default): runs `BooksPresence --garden-frame-budget`, the same check CI runs. It
#    builds the dashboard's and menu panel's gardens as layers without a window, steps 15 virtual
#    minutes of growth on a virtual clock, and reports main-thread CPU per step, idle CPU per
#    window (target <= 1.5%) and the one-off costs (first build, return from hidden, glass blur).
#    It exits non-zero when any limit in GardenFrameBudget is exceeded. Writes living-garden-budget.json.
# 2. Live (--live): opens the synthetic Today dashboard in a real window, waits for the garden to
#    grow and settle, then samples the process's CPU over WINDOW seconds, dark and light. That is
#    the app's share only: the render server's compositing of the layers shows in Activity
#    Monitor's Energy tab (WindowServer), not here. A real window takes the screen, so run this
#    only when the Mac is free, and never from an agent session.
set -euo pipefail
cd "$(dirname "$0")/.."
LIVE=0
if [[ "${1:-}" == "--live" ]]; then LIVE=1; shift; fi
BIN="${1:-${BOOKSPRESENCE_BUILD_DIR:-.build/local}}/BooksPresence"
SETTLE="${SETTLE:-60}"
WINDOW="${WINDOW:-60}"
REPORT="${REPORT:-living-garden-budget.json}"
[[ -x "$BIN" ]] || { echo "No build at $BIN. Run scripts/build-local.sh first." >&2; exit 1; }

echo "== Frame budget (headless) =="
"$BIN" --garden-frame-budget "$REPORT"
echo "Report: $REPORT"
(( LIVE )) || exit 0

echo
echo "== Live idle CPU: ${SETTLE}s to settle, then ${WINDOW}s sampled =="
cpu_seconds() { ps -o time= -p "$1" | tr -d ' ' | awk -F'[:.]' '{ printf "%.2f", $1*60+$2+$3/100 }'; }
status=0
for appearance in dark light; do
  "$BIN" --preview-library --preview-section today --preview-appearance "$appearance" >/dev/null 2>&1 &
  pid=$!
  sleep "$SETTLE"
  before=$(cpu_seconds "$pid"); sleep "$WINDOW"; after=$(cpu_seconds "$pid")
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  result=$(echo "$after $before $WINDOW" | awk '{ printf "%.2f", ($1-$2)/$3*100 }')
  verdict=$(echo "$result" | awk '{ print ($1 <= 1.5) ? "within the 1.5% target" : "OVER the 1.5% target" }')
  echo "today/$appearance idle: ${result}% CPU over ${WINDOW}s, $verdict"
  echo "$verdict" | grep -q OVER && status=1
done
exit $status
