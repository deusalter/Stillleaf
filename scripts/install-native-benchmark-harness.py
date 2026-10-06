#!/usr/bin/env python3
"""Overlay the identical benchmark harness on a baseline checkout; preserve product differences."""
from pathlib import Path
import sys
source = Path(__file__).resolve().parents[1]
target = Path(sys.argv[1])
# Baseline revisions predate DevTools/ and keep the harness beside the app sources.
(target / 'Sources/BooksPresence/UISettledBenchmark.swift').write_text((source / 'Sources/BooksPresence/DevTools/UISettledBenchmark.swift').read_text())
p = target / 'Sources/BooksPresence/HistoryView.swift'
s = p.read_text()
s = s.replace('    @State private var reviewInterval:', '    private let benchmarkReady: ((HistoryAtlasKey) -> Void)?\n    @State private var reviewInterval:')
s = s.replace('anchor: Date = Date()) {', 'anchor: Date = Date(), benchmarkReady: ((HistoryAtlasKey) -> Void)? = nil) {').replace('        self.model = model', '        self.model = model\n        self.benchmarkReady = benchmarkReady', 1)
s = s.replace('                        .transition(reduceMotion ? .identity : .opacity)', '                        .transition(reduceMotion ? .identity : .opacity)\n                        .onAppear { benchmarkReady?(prepared.key) }')
assert 'benchmarkReady?(prepared.key)' in s
p.write_text(s)
p = target / 'Sources/BooksPresence/BooksPresenceApp.swift'
s = p.read_text()
start = (source / 'Sources/BooksPresence/BooksPresenceApp.swift').read_text()
branch = start[start.index('        if let index = CommandLine.arguments.firstIndex(of: "--benchmark-settled-ui")'):start.index('        if CommandLine.arguments.contains("--benchmark-ui")')]
assert '--benchmark-settled-ui' not in s
s = s.replace('        if CommandLine.arguments.contains("--benchmark-ui")', branch + '        if CommandLine.arguments.contains("--benchmark-ui")')
p.write_text(s)
