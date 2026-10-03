#!/usr/bin/env python3
"""Exercise success, real failure, and forced termination without a Mac or EPUB."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).with_name('run-native-reader-smoke.py')


class ReaderWatchdogTests(unittest.TestCase):
    def check_run(self, source, expected, timeout=2, stubborn_child=False):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            child_pid = output / 'child.pid'
            if stubborn_child:
                child = ("import os, signal, time; from pathlib import Path; "
                         "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                         f"Path({str(child_pid)!r}).write_text(str(os.getpid())); "
                         "print('checkpoint child', flush=True); time.sleep(120)")
                # The descendant inherits the wrapper's output pipe and ignores
                # TERM too. Only process-group KILL can finish and close stdout.
                source = ("import signal, subprocess, sys, time; "
                          "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                          f"subprocess.Popen([sys.executable, '-u', '-c', {child!r}]); "
                          "print('checkpoint parent', flush=True); time.sleep(120)")
            result = subprocess.run([sys.executable, str(RUNNER), '--timeout', str(timeout), '--output', str(output), '--',
                                     sys.executable, '-u', '-c', source], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertIn('checkpoint', (output / 'application.log').read_text())
            record = json.loads((output / 'result.json').read_text())
            self.assertEqual(record['timedOut'], expected == 124)
            self.assertIsNotNone(record['processExitCode'])
            if expected == 124:
                self.assertTrue((output / 'processes.txt').exists())
                self.assertTrue((output / 'sample-command.log').exists())
                if stubborn_child:
                    self.assertEqual(record['processExitCode'], -9, 'a TERM-ignoring parent requires KILL')
                    pid = int(child_pid.read_text())
                    # A killed orphan may briefly be a zombie awaiting init;
                    # it must never remain a live process retaining the pipe.
                    state = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                    self.assertTrue(not state or state.startswith('Z'), f'descendant still running: {pid} {state}')
                    self.assertIn('checkpoint child', (output / 'application.log').read_text())
            else:
                self.assertEqual(record['exitCode'], expected)

    def test_success_is_preserved(self):
        self.check_run("print('checkpoint')", 0)

    def test_application_failure_is_not_hidden(self):
        self.check_run("print('checkpoint'); raise SystemExit(17)", 17)

    def test_hang_is_diagnosed_and_fails(self):
        self.check_run("", 124, timeout=1, stubborn_child=True)


if __name__ == '__main__':
    unittest.main()
