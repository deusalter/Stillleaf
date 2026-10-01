#!/usr/bin/env python3
"""Evaluate repeated matched cloud samples; fail CI on an unaccepted regression."""
import json, math, sys
from pathlib import Path

def p95(values):
    values = sorted(values)
    assert len(values) >= 20, 'Twenty measured samples are required'
    assert all(math.isfinite(x) and x >= 0 for x in values)
    return values[math.ceil(len(values) * .95) - 1]

baseline, candidate, feedback = [json.loads(Path(p).read_text()) for p in sys.argv[1:4]]
checks = []
for scale in ('day', 'week', 'month', 'year'):
    for metric in ('settledMs', 'maxMainWorkMs'):
        before = p95([s[metric] for s in baseline['samples'] if s['scale'] == scale])
        after = p95([s[metric] for s in candidate['samples'] if s['scale'] == scale])
        # Main-loop readiness has 1 ms sampling and shared cloud scheduling noise.
        # Preserve the 10% bound for meaningful costs; at small costs allow at
        # most 5 ms absolute variation, never an unconstrained relative waiver.
        limit = max(before * 1.10, before + 5)
        checks.append({'metric': scale + '.' + metric, 'baselineP95Ms': before, 'candidateP95Ms': after, 'limitMs': limit, 'passed': after <= limit})
for metric, limit in [('bookmarkVisibleMs', 18.7), ('popoverVisibleMs', 250), ('buttonFrameworkMs', 16)]:
    after = p95(feedback[metric])
    checks.append({'metric': metric, 'candidateP95Ms': after, 'limitMs': limit, 'passed': after <= limit})
result = {'method': '20 samples per metric, two warmups; p95 nearest rank; matched baseline/candidate on same cloud runner; GPU/optical presentation excluded', 'checks': checks, 'passed': all(c['passed'] for c in checks)}
Path(sys.argv[4]).write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
sys.exit(0 if result['passed'] else 1)
