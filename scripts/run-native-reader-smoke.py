#!/usr/bin/env python3
"""Bound a native reader check; retain output and sample a stalled process before failing."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def stop(process):
    if process is None:
        return
    # Kill the dedicated group, including any descendants retaining stdout.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=3)


def diagnose(process, output):
    for name, command, limit in [
        ('processes.txt', ['/bin/ps', '-axo', 'pid,ppid,pgid,etime,state,comm'], 5),
        ('sample-command.log', ['/usr/bin/sample', str(process.pid), '5', '1', '-mayDie', '-file', str(output / 'stacks.txt')], 15),
    ]:
        with (output / name).open('wb') as log:
            try:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=limit, check=False)
            except (OSError, subprocess.TimeoutExpired) as error:
                log.write((str(error) + '\n').encode())


def run(command, output, timeout):
    output.mkdir(parents=True, exist_ok=True)
    process = pump = None
    started = time.monotonic()
    result = {'command': command, 'timeoutSeconds': timeout, 'timedOut': False}
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        result['pid'] = process.pid

        def forward():
            with (output / 'application.log').open('wb') as log:
                for line in iter(process.stdout.readline, b''):
                    log.write(line); log.flush()
                    sys.stdout.buffer.write(line); sys.stdout.buffer.flush()

        pump = threading.Thread(target=forward, daemon=True)
        pump.start()
        try:
            code = process.wait(timeout=timeout)
            result['exitCode'] = code
            return code if code >= 0 else 128 - code
        except subprocess.TimeoutExpired:
            result['timedOut'] = True
            print(f'native-reader-watchdog: exceeded {timeout:g}s; sampling before termination', flush=True)
            diagnose(process, output)
            return 124
    except OSError as error:
        result['error'] = str(error)
        print(f'native-reader-watchdog: {error}', file=sys.stderr, flush=True)
        return 1
    finally:
        stop(process)
        if pump is not None:
            pump.join(timeout=2)
        if process is not None:
            result['processExitCode'] = process.poll()
        result['elapsedSeconds'] = round(time.monotonic() - started, 3)
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, default=300)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or args.timeout <= 0:
        parser.error('provide a command and a positive timeout')
    return run(command, args.output.resolve(), args.timeout)


if __name__ == '__main__':
    sys.exit(main())
