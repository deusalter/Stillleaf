#!/usr/bin/env python3
"""TEMPORARY: baseline vs main-before-fix vs fix, Year only, interleaved whole-process runs."""
import json, math, os, statistics, subprocess, sys
from pathlib import Path
apps = {'baseline': Path(sys.argv[1]).resolve(), 'main-before-fix': Path(sys.argv[2]).resolve(), 'fix': Path(sys.argv[3]).resolve()}
out = Path(sys.argv[4]); out.mkdir(parents=True, exist_ok=True)
ROUNDS = int(os.environ.get('ROUNDS', '8'))
metrics = ('settledMs', 'maxMainWorkMs', 'settledProcessCPUMs', 'maxMainThreadCPUMs')
samples = {k: {m: [] for m in metrics} for k in apps}
perbatch = {k: [] for k in apps}
labels = list(apps)
for r in range(ROUNDS):
    order = labels[r % 3:] + labels[:r % 3]
    if r % 2: order = order[::-1]
    for label in order:
        path = out / f'{r}-{label}.json'
        subprocess.run([str(apps[label]), '--benchmark-settled-ui', str(path)], env=dict(os.environ, STILLLEAF_BENCH_SCALES='year', STILLLEAF_UI_BENCHMARK_SAMPLES='20'), check=True, stdout=subprocess.DEVNULL)
        batch = json.loads(path.read_text())['samples']
        perbatch[label].append(statistics.median(s['settledMs'] for s in batch))
        for s in batch:
            for m in metrics: samples[label][m].append(s[m])
def pct(v, p): v = sorted(v); return v[min(len(v) - 1, math.ceil(len(v) * p) - 1)]
base = {m: pct(samples['baseline'][m], .95) for m in metrics}
lines = ['Year only, interleaved whole-process batches; p50 / p95 / p95 relative to the baseline p95 (gate limit is 1.10)']
lines.append(f'{"build":18s} n   ' + ' '.join(f'{m[:16]:>24s}' for m in metrics))
for label in labels:
    cells = []
    for m in metrics:
        v = samples[label][m]; cells.append(f'{statistics.median(v):6.0f}/{pct(v,.95):6.0f}/{pct(v,.95)/base[m]:4.2f}x')
    lines.append(f'{label:18s} {len(samples[label][metrics[0]]):3d} ' + ' '.join(f'{c:>24s}' for c in cells))
lines.append('per-batch median settledMs: ' + '; '.join(f'{k}: ' + ' '.join(f'{x:.0f}' for x in v) for k, v in perbatch.items()))
text = '\n'.join(lines); print(text); (out / 'summary.txt').write_text(text)
