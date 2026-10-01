#!/usr/bin/env python3
"""Counterbalance identical History measurements without discarding measured tails."""
import json
import os
from pathlib import Path
import subprocess
import sys

baseline, candidate, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), Path(sys.argv[3])
output.mkdir(parents=True, exist_ok=True)
batches = output / 'native-performance-batches'
batches.mkdir(exist_ok=True)
apps = {'baseline': baseline, 'candidate': candidate}
combined = {label: {'samples': [], 'warmups': [], 'batches': []} for label in apps}
environment = dict(os.environ, STILLLEAF_UI_BENCHMARK_SAMPLES='5')
for batch in range(4):
    order = ('baseline', 'candidate') if batch in (0, 3) else ('candidate', 'baseline')
    for position, label in enumerate(order):
        path = batches / f'{batch}-{position}-{label}.json'
        subprocess.run([str(apps[label]), '--benchmark-settled-ui', str(path)], env=environment, check=True)
        result = json.loads(path.read_text())
        for scale in ('day', 'week', 'month', 'year'):
            assert sum(s['scale'] == scale for s in result['samples']) == 5
            assert sum(s['scale'] == scale for s in result['warmups']) == 2
        assert all(s['viewportWidth'] == 960 and s['viewportHeight'] == 660 for s in result['samples'] + result['warmups'])
        for key in ('samples', 'warmups'):
            combined[label][key].extend(dict(sample, batch=batch, position=position) for sample in result[key])
        combined[label]['batches'].append({'batch': batch, 'position': position, 'file': path.name})
for label, result in combined.items():
    result['method'] = 'Four counterbalanced five-sample batches per scale; each fresh process has two recorded warmups per scale; all twenty measured samples retained; baseline-first, candidate-first, candidate-first, baseline-first'
    (output / f'{label}-settled-ui.json').write_text(json.dumps(result, indent=2))
print('matched-native-benchmark: 20 samples per scale/build retained in counterbalanced batches')
