#!/usr/bin/env python3
"""TEMPORARY: (1) baseline vs main-before-fix vs fix, whole processes interleaved; (2) fix variants interleaved per sample."""
import json, math, os, statistics, subprocess, sys
from pathlib import Path
apps = {'baseline': Path(sys.argv[1]).resolve(), 'main-before-fix': Path(sys.argv[2]).resolve(), 'fix': Path(sys.argv[3]).resolve()}
out = Path(sys.argv[4]); out.mkdir(parents=True, exist_ok=True)
metrics = ('settledMs', 'maxMainWorkMs', 'settledProcessCPUMs', 'maxMainThreadCPUMs')
def pct(v, p): v = sorted(v); return v[min(len(v) - 1, math.ceil(len(v) * p) - 1)]
def run(app, path, **env):
    subprocess.run([str(app), '--benchmark-settled-ui', str(path)], env=dict(os.environ, STILLLEAF_BENCH_SCALES='year', **env), check=True, stdout=subprocess.DEVNULL)
    return json.loads(path.read_text())['samples']
ROUNDS = int(os.environ.get('ROUNDS', '6'))
samples = {k: {m: [] for m in metrics} for k in apps}; perbatch = {k: [] for k in apps}
labels = list(apps)
for r in range(ROUNDS):
    order = labels[r % 3:] + labels[:r % 3]
    if r % 2: order = order[::-1]
    for label in order:
        batch = run(apps[label], out / f'ab-{r}-{label}.json', STILLLEAF_UI_BENCHMARK_SAMPLES='20')
        perbatch[label].append(statistics.median(s['settledMs'] for s in batch))
        for s in batch:
            for m in metrics: samples[label][m].append(s[m])
base = {m: pct(samples['baseline'][m], .95) for m in metrics}
lines = ['A/B: Year only, interleaved whole-process batches; p50 / p95 / p95 relative to baseline p95 (gate limit 1.10)']
lines.append(f'{"build":18s} n   ' + ' '.join(f'{m[:16]:>24s}' for m in metrics))
for label in labels:
    cells = []
    for m in metrics:
        v = samples[label][m]; cells.append(f'{statistics.median(v):6.0f}/{pct(v,.95):6.0f}/{pct(v,.95)/base[m]:4.2f}x')
    lines.append(f'{label:18s} {len(samples[label][metrics[0]]):3d} ' + ' '.join(f'{c:>24s}' for c in cells))
lines.append('per-batch median settledMs: ' + '; '.join(f'{k}: ' + ' '.join(f'{x:.0f}' for x in v) for k, v in perbatch.items()))
VARIANTS = ['none', 'plainLabel', 'captionText', 'titleFrame', 'labelOneText', 'totalsOneText', 'lazyColumns', 'plainLabel,totalsOneText,captionText']
vs = {v: {m: [] for m in metrics} for v in VARIANTS}
for r in range(int(os.environ.get('VROUNDS', '3'))):
    for s in run(apps['fix'], out / f'var-{r}.json', STILLLEAF_UI_BENCHMARK_SAMPLES=str(25 * len(VARIANTS)), STILLLEAF_YEAR_VARIANTS=';'.join('' if v == 'none' else v for v in VARIANTS)):
        for m in metrics: vs[s['variant'] or 'none'][m].append(s[m])
none = {m: statistics.median(vs['none'][m]) for m in metrics}
lines += ['', 'Variants on the fix, interleaved per sample in one process; p50 / p95 and p50 relative to the fix', f'{"variant":44s} n   ' + ' '.join(f'{m[:16]:>22s}' for m in metrics)]
for v in VARIANTS:
    cells = [f'{statistics.median(vs[v][m]):5.0f}/{pct(vs[v][m],.95):5.0f} {statistics.median(vs[v][m])/none[m]:4.2f}x' for m in metrics]
    lines.append(f'{v:44s} {len(vs[v][metrics[0]]):3d} ' + ' '.join(f'{c:>22s}' for c in cells))
text = '\n'.join(lines); print(text); (out / 'summary.txt').write_text(text)
