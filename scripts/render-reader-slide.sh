#!/bin/bash
# Builds and previews the renderer in isolated browser/WKWebView fixtures only.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/.local/reader-slide"
mkdir -p "$OUT"
npm --prefix Reader/desktop/reader run build
SLIDE_BROWSER=webkit node --test Reader/desktop/reader/test/page-slide.test.mjs
xcrun swiftc -parse-as-library scripts/native-reader-slide-preview.swift -o "$OUT/native-preview"
"$OUT/native-preview" "$PWD/Reader/desktop/reader/dist" "$OUT/native"
ffmpeg -y -loglevel error -i "$OUT/webkit-reader-slide.webm" -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT/webkit-reader-slide.mp4"
ffmpeg -y -loglevel error -framerate 7.8125 -i "$OUT/native/sample-%02d.png" \
  -vf 'scale=1000:800,tpad=start_duration=0.4:start_mode=clone:stop_duration=0.6:stop_mode=clone' \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT/native-sampled-slide.mp4"
cat > "$OUT/index.html" <<'HTML'
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Stillleaf reader slide</title>
<style>body{font:16px system-ui;max-width:1000px;margin:40px auto;padding:0 24px;background:#f0f8f5;color:#183d33}h1{font-size:28px}video,img{width:100%;border:1px solid #cbded6;border-radius:8px}p{line-height:1.6}section{margin-block:36px}</style>
<h1>Stillleaf — sliding pages</h1><p>The actual EPUB renderer with synthetic chapters. No changes to an installed app or personal reading data.</p>
<section><h2>WebKit interaction recording</h2><p>Forward/back, trackpad, rapid reversals, chapter boundaries, Reduce Motion, resize and RTL. The first transition pauses for a geometry assertion; subsequent transitions run normally. Test capture overhead is not display-performance evidence.</p><video controls muted playsinline src="webkit-reader-slide.mp4"></video></section>
<section><h2>Native WKWebView chapter slide</h2><p>Native render samples at 32 ms intervals, played 4× slower for inspection. WKWebView snapshots can freeze compositor-driven playback, so this sequence explicitly samples paused animation times. It demonstrates rendering, not real display cadence.</p><video controls loop muted playsinline src="native-sampled-slide.mp4"></video></section>
<section><h2>Native intermediate frame</h2><img src="native/sample-02.png" alt="The tail of chapter one sliding left while chapter two enters from the right"></section>
</html>
HTML
printf 'Preview: %s/index.html\n' "$OUT"
