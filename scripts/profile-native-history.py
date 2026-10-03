#!/usr/bin/env python3
"""Collect separate sampled stacks; these instrumented runs never feed the gates."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def profile(label, application, output, sampler=Path('/usr/bin/sample')):
    trace = output / f'{label}-stacks.txt'
    measurement = output / f'{label}-instrumented-ui.json'
    result = {'build': label, 'application': str(application), 'diagnosticOnly': True}
    app = sample = None
    started = time.monotonic()
    trace.unlink(missing_ok=True)
    measurement.unlink(missing_ok=True)
    try:
        with (output / f'{label}-app.log').open('w') as app_log, (output / f'{label}-sample.log').open('w') as sample_log:
            app = subprocess.Popen([str(application), '--benchmark-settled-ui', str(measurement)],
                env=dict(os.environ, STILLLEAF_UI_BENCHMARK_SAMPLES='20'), stdout=app_log, stderr=subprocess.STDOUT)
            # Full process stacks include the main thread's SwiftUI/AppKit work
            # and the worker preparation. -mayDie preserves a trace if it exits
            # before the 30-second sampling window ends.
            sample = subprocess.Popen([str(sampler), str(app.pid), '30', '1', '-mayDie', '-file', str(trace)],
                stdout=sample_log, stderr=subprocess.STDOUT)
            result['applicationExitCode'] = app.wait(timeout=60)
            result['sampleExitCode'] = sample.wait(timeout=max(0.1, 60 - (time.monotonic() - started)))
    except (OSError, subprocess.TimeoutExpired) as error:
        result['error'] = str(error)
    finally:
        stop(app)
        stop(sample)
    result['elapsedSeconds'] = round(time.monotonic() - started, 3)
    result['traceWritten'] = trace.exists() and trace.stat().st_size > 0
    (output / f'{label}-profile.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    return result


def main():
    baseline, candidate, output = map(lambda value: Path(value).resolve(), sys.argv[1:])
    # Keep every diagnostic file in a separate directory. In particular, never
    # overwrite baseline/candidate-settled-ui.json used by the canonical gate.
    output = output / 'native-history-profile'
    output.mkdir(parents=True, exist_ok=True)
    results = [profile(label, application, output)
               for label, application in [('baseline', baseline), ('candidate', candidate)]]
    return 0 if all(result.get('applicationExitCode') == 0 and result['traceWritten'] for result in results) else 1


if __name__ == '__main__':
    sys.exit(main())
