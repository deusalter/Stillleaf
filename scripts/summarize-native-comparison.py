#!/usr/bin/env python3
"""Summarize a supplemental revision comparison; canonical CI gates are separate."""
import json
import math
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1])
data = {name: json.loads((root / f'{name}-settled-ui.json').read_text()) for name in ('baseline', 'candidate')}
rows = []
for scale in ('day', 'week', 'month', 'year'):
    for metric in ('settledMs', 'maxMainWorkMs', 'settledProcessCPUMs', 'maxMainThreadCPUMs'):
        row = {'scale': scale, 'metric': metric}
        for name, measurements in data.items():
            samples = [s for s in measurements['samples'] if s['scale'] == scale]
            values = sorted(s[metric] for s in samples)
            assert len(values) == 80 and all(math.isfinite(v) and v >= 0 for v in values)
            row[name] = {'medianMs': statistics.median(values), 'p95Ms': values[math.ceil(len(values) * .95) - 1],
                         'batchMediansMs': [statistics.median(s[metric] for s in samples if s['batch'] == batch) for batch in range(4)]}
        rows.append(row)
report = {'method': 'Supplemental same-runner comparison; all 80 samples retained per scale/build. Canonical regression gates unchanged.',
          'revisions': {name: (root / f'{name}-revision.txt').read_text().strip() for name in data}, 'metrics': rows}
(root / 'comparison-summary.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
