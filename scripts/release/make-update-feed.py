#!/usr/bin/env python3
"""Write the update feed (macos.json) and release manifest for one release artifact.

Usage:
  make-update-feed.py --app Stillleaf.app --artifact Stillleaf-1.5.0.dmg \
      --download-url https://HOST/download/Stillleaf-1.5.0.dmg \
      [--notes-url https://HOST/releases/1.5.0] --output-dir DIR

The feed format is documented in docs/DISTRIBUTION.md#update-feed and parsed by
BooksCore/UpdateFeed.swift. Its artifact fields match the website's ReleaseArtifact
(url, version, sha256), so one manifest can drive both.
"""
import argparse
import datetime
import hashlib
import json
import plistlib
import subprocess
from pathlib import Path
from urllib.parse import urlparse


def https(value):
    url = urlparse(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment:
        raise argparse.ArgumentTypeError(f'{value!r} must be a credential-free https URL')
    return value


parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--artifact', type=Path, required=True)
parser.add_argument('--download-url', type=https, required=True)
parser.add_argument('--notes-url', type=https)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()

with (args.app / 'Contents/Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
digest = hashlib.sha256(args.artifact.read_bytes()).hexdigest()
commit = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip() or None
latest = {
    'version': info['CFBundleShortVersionString'],
    'build': int(info['CFBundleVersion']),
    'minimumSystemVersion': info['LSMinimumSystemVersion'],
    'publishedAt': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
    'url': args.download_url,
    'sha256': digest,
    'size': args.artifact.stat().st_size,
}
if args.notes_url:
    latest['releaseNotesURL'] = args.notes_url

args.output_dir.mkdir(parents=True, exist_ok=True)
feed = {'schemaVersion': 1, 'bundleIdentifier': info['CFBundleIdentifier'], 'latest': latest}
(args.output_dir / 'macos.json').write_text(json.dumps(feed, indent=2) + '\n')
manifest = dict(latest, artifact=args.artifact.name, commit=commit, verified=False)
(args.output_dir / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'update-feed: {latest["version"]} ({latest["build"]}) sha256 {digest}')
