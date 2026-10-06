#!/usr/bin/env python3
"""TEMPORARY: baseline vs candidate, and Year-view variants interleaved sample by sample in one process."""
import json, math, os, statistics, subprocess, sys
from pathlib import Path
baseline, candidate, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
VARIANTS = ['none', 'noCover', 'coverLite', 'plainButton', 'menuBare', 'noA11y', 'baseLabel', 'noLabel', 'noCanvas',
            'noPanelGlass', 'lightWrap', 'noTzPill', 'baseLabel,noPanelGlass,lightWrap,noTzPill']
metrics = ('settledMs', 'maxMainWorkMs', 'settledProcessCPUMs', 'maxMainThreadCPUMs')
ROUNDS = int(os.environ.get('ROUNDS', '3'))
samples = {'baseline': {m: [] for m in metrics}}
samples.update({v: {m: [] for m in metrics} for v in VARIANTS})
def run(app, path, env):
    subprocess.run([str(app), '--benchmark-settled-ui', str(path)], env=dict(os.environ, STILLLEAF_BENCH_SCALES='year', **env), check=True, stdout=subprocess.DEVNULL)
    return json.loads(path.read_text())['samples']
for r in range(ROUNDS):
    for s in run(baseline, out / f'{r}-baseline.json', {'STILLLEAF_UI_BENCHMARK_SAMPLES': '20'}):
        for m in metrics: samples['baseline'][m].append(s[m])
    reps = int(os.environ.get('REPS', '20'))
    for s in run(candidate, out / f'{r}-variants.json', {'STILLLEAF_UI_BENCHMARK_SAMPLES': str(reps * len(VARIANTS)), 'STILLLEAF_YEAR_VARIANTS': ';'.join('' if v == 'none' else v for v in VARIANTS)}):
        for m in metrics: samples[s['variant'] or 'none'][m].append(s[m])
def pct(v, p): v = sorted(v); return v[min(len(v) - 1, math.ceil(len(v) * p) - 1)]
base = {m: statistics.median(samples['baseline'][m]) for m in metrics}
none = {m: statistics.median(samples['none'][m]) for m in metrics}
lines = [f'{"variant":58s} n    ' + ' '.join(f'{m[:14]:>21s}' for m in metrics), '(p50 / p95 ; p50 relative to baseline p50)']
for label in samples:
    cells = []
    for m in metrics:
        v = samples[label][m]; cells.append(f'{statistics.median(v):5.0f}/{pct(v,.95):5.0f} {statistics.median(v)/base[m]:4.2f}x')
    lines.append(f'{label:58s} {len(samples[label][metrics[0]]):4d} ' + ' '.join(f'{c:>21s}' for c in cells))
text = '\n'.join(lines); print(text); (out / 'summary.txt').write_text(text)
