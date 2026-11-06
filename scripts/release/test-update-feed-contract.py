#!/usr/bin/env python3
"""make-update-feed.py must write the feed in Tests/Fixtures/update-feed/macos.json, byte for byte.

The website's test checks its own output against the same file, and the app's tests parse it, so
the three stay one contract. The checksum, size and time are computed from the artifact, so they
are compared by type and then replaced with the fixture's values.
"""
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
contract_text = (ROOT / 'Tests/Fixtures/update-feed/macos.json').read_text()
contract = json.loads(contract_text)['latest']

with tempfile.TemporaryDirectory() as temporary:
    temp = Path(temporary)
    (temp / 'Stillleaf.app/Contents').mkdir(parents=True)
    with (temp / 'Stillleaf.app/Contents/Info.plist').open('wb') as handle:
        plistlib.dump({'CFBundleIdentifier': 'com.bookspresence.app', 'CFBundleShortVersionString': contract['version'],
                       'CFBundleVersion': str(contract['build']), 'LSMinimumSystemVersion': contract['minimumSystemVersion']}, handle)
    (temp / 'Stillleaf.dmg').write_bytes(b'synthetic disk image')
    subprocess.run([sys.executable, str(ROOT / 'scripts/release/make-update-feed.py'), '--app', str(temp / 'Stillleaf.app'),
                    '--artifact', str(temp / 'Stillleaf.dmg'), '--download-url', contract['url'],
                    '--notes-url', contract['releaseNotesURL'], '--output-dir', str(temp / 'out')],
                   check=True, cwd=ROOT, stdout=subprocess.DEVNULL)
    feed = json.loads((temp / 'out/macos.json').read_text())
    manifest = json.loads((temp / 'out/release-manifest.json').read_text())

latest = feed['latest']
for key in ['publishedAt', 'sha256', 'size']:
    assert type(latest[key]) is type(contract[key]), f'{key} has the wrong type'
    latest[key] = contract[key]
written = json.dumps(feed, indent=2) + '\n'
assert written == contract_text, f'make-update-feed.py drifted from the shared feed:\n{written}'
# The website's ReleaseArtifact is filled from the manifest, so it carries every feed field.
missing = set(contract) - set(manifest)
assert not missing, f'release-manifest.json lacks {sorted(missing)}'
assert manifest['verified'] is False, 'A new manifest must start unverified'
print('update-feed-contract: passed')
