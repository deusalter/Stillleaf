#!/bin/bash
# Live check of the menu bar panel's garden cost. It needs a real Stillleaf
# process and a person to click the status item, so it cannot run on CI or in
# offscreen mode. Usage: scripts/measure-menu-panel-cpu.sh [pid]
# Without a pid it uses the newest running BooksPresence or Stillleaf process.
set -euo pipefail
PID="${1:-$(pgrep -nx 'BooksPresence|Stillleaf' || true)}"
[[ -n "$PID" ]] || { echo "Start Stillleaf first, or pass its pid." >&2; exit 1; }
sample() { # label seconds
  local total=0 n=0 peak=0 value
  for ((i = 0; i < $2; i++)); do
    value=$(ps -o %cpu= -p "$PID" | tr -d ' ')
    total=$(echo "$total + $value" | bc -l); n=$((n + 1))
    peak=$(echo "if ($value > $peak) $value else $peak" | bc -l)
    sleep 1
  done
  printf '%-34s mean %5.1f%%  peak %5.1f%% CPU over %ss\n' "$1" "$(echo "$total / $n" | bc -l)" "$peak" "$2"
}
echo "Close the menu panel. Sampling the idle baseline..."
sample "panel closed (baseline)" 15
read -r -p "Click the status item to OPEN the panel now, then press Return (Animated garden)... " _
sample "panel open, vines growing (0-8s)" 8
sample "panel open, grown and breathing" 15
read -r -p "CLOSE the panel (click elsewhere), then press Return... " _
sleep 3
sample "panel closed again" 15
cat <<'TXT'

Expected: closed samples match the baseline within noise (a few tenths of a
percent). Growing may reach tens of percent for a few seconds; grown and
breathing should be a small fraction of that (the light band moves on the
compositor). Repeat with Settings > Appearance > Garden set to Still and Off:
Still and Off should add nothing over the baseline once the panel has painted.
TXT
