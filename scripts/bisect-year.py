#!/usr/bin/env python3
"""TEMPORARY: interleave baseline and Year-view variants on one runner and report p50/p95."""
import json, math, os, subprocess, sys
from pathlib import Path
baseline, candidate, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
VARIANTS = ['', 'plainButton', 'menuBare', 'noCover', 'noA11y', 'noPanelGlass', 'lightWrap', 'noTzPill',
            'plainButton,noPanelGlass,lightWrap,noTzPill', 'plainButton,noPanelGlass,lightWrap,noTzPill,noCover,noA11y']
ROUNDS = int(os.environ.get('ROUNDS', '4'))
runs = [('baseline', baseline, '')] + [('cand:' + (v or 'none'), candidate, v) for v in VARIANTS]
metrics = ('settledMs', 'maxMainWorkMs', 'settledProcessCPUMs', 'maxMainThreadCPUMs')
samples = {label: {m: [] for m in metrics} for label, _, _ in runs}
for r in range(ROUNDS):
    order = runs[r % len(runs):] + runs[:r % len(runs)]
    if r % 2: order = order[::-1]
    for label, app, variant in order:
        path = out / f'{r}-{label.replace(":", "_").replace(",", "+")}.json'
        env = dict(os.environ, STILLLEAF_UI_BENCHMARK_SAMPLES='20', STILLLEAF_BENCH_SCALES='year', STILLLEAF_YEAR_VARIANT=variant)
        subprocess.run([str(app), '--benchmark-settled-ui', str(path)], env=env, check=True, stdout=subprocess.DEVNULL)
        for s in json.loads(path.read_text())['samples']:
            for m in metrics: samples[label][m].append(s[m])
def pct(v, p): v = sorted(v); return v[min(len(v) - 1, math.ceil(len(v) * p) - 1)]
base = {m: pct(samples['baseline'][m], .95) for m in metrics}
lines = [f'{"variant":78s} ' + ' '.join(f'{m[:14]:>22s}' for m in metrics), '(p50 / p95 / p95 as fraction of baseline p95)']
for label, _, _ in runs:
    cells = []
    for m in metrics:
        v = samples[label][m]; cells.append(f'{pct(v,.5):6.0f}/{pct(v,.95):6.0f}/{pct(v,.95)/base[m]:5.2f}')
    lines.append(f'{label:78s} ' + ' '.join(f'{c:>22s}' for c in cells))
text = '\n'.join(lines); print(text); (out / 'summary.txt').write_text(text)
