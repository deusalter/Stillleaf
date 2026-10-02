#!/bin/bash
# Native before/after fixtures; does not start tracking or install the application.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-.local/shared-style}"
BASE="${2:-029b1be}"
mkdir -p "$OUT/baseline-sources"
for source in ReadingLayout ReadingMotion ReadingControls; do
  git show "$BASE:Sources/BooksPresence/$source.swift" > "$OUT/baseline-sources/$source.swift"
done
COMMON=(Sources/BooksPresence/Theme.swift Sources/BooksPresence/ThemeStore.swift Sources/BooksPresence/NativeChrome.swift Sources/BooksPresence/ReadingButtonStyle.swift)
FLAGS=(-parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0")
xcrun swiftc "${FLAGS[@]}" "${COMMON[@]}" "$OUT"/baseline-sources/*.swift scripts/shared-style-preview.swift -o "$OUT/before-preview"
xcrun swiftc "${FLAGS[@]}" "${COMMON[@]}" Sources/BooksPresence/ReadingLayout.swift Sources/BooksPresence/ReadingMotion.swift Sources/BooksPresence/ReadingControls.swift scripts/shared-style-preview.swift -o "$OUT/after-preview"
"$OUT/before-preview" "$OUT/before"
"$OUT/after-preview" "$OUT/after"
for mode in motion reduced; do
  ffmpeg -y -loglevel error -framerate 60 -i "$OUT/before/light-$mode/%03d.png" -framerate 60 -i "$OUT/after/light-$mode/%03d.png" \
    -filter_complex '[0:v][1:v]hstack=inputs=2,scale=1280:-2' -c:v libx264 -pix_fmt yuv420p "$OUT/comparison-$mode.mp4"
done
for appearance in light dark; do
  ffmpeg -y -loglevel error -i "$OUT/before/$appearance-motion/000.png" -i "$OUT/after/$appearance-motion/000.png" \
    -filter_complex '[0:v][1:v]hstack=inputs=2' -frames:v 1 "$OUT/comparison-$appearance.png"
done
cat > "$OUT/index.html" <<'HTML'
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Stillleaf — shared typography and motion</title>
<style>body{font:16px system-ui;margin:40px auto;padding:0 24px;max-width:1280px;background:#f5f8f5;color:#183d33}h1{font-size:28px}img,video{width:100%;border:1px solid #d0ded6;border-radius:12px}p{max-width:850px;line-height:1.5}section{margin:36px 0}a{color:inherit}</style>
<h1>Stillleaf: shared typography and motion</h1>
<p>Before on the left; after on the right. Native SwiftUI component renders using synthetic content. The serif book title and button treatment are unchanged.</p>
<section><h2>Light appearance</h2><img src="comparison-light.png" alt="Before and after native type hierarchy in light appearance"></section>
<section><h2>Dark appearance</h2><img src="comparison-dark.png" alt="Before and after native type hierarchy in dark appearance"></section>
<section><h2>Selection and rapid reversal</h2><p>One ordinary change, three changes four frames apart, then a final selection. Play or scrub to compare. These frames demonstrate native interpolation, not measured display pacing or input latency.</p><video controls loop muted playsinline src="comparison-motion.mp4"></video></section>
<section><h2>Reduce Motion</h2><p>The same sequence with Reduce Motion injected into the preview environment. Only the three settled states appear.</p><video controls loop muted playsinline src="comparison-reduced.mp4"></video></section>
</html>
HTML
printf 'Preview: %s/index.html\n' "$OUT"
