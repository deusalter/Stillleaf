#!/usr/bin/env python3
"""Verify a packaged Stillleaf release the way Gatekeeper will see it.

Usage:
  verify-release.py Stillleaf.app [Stillleaf.dmg] --level adhoc|signed|notarized

adhoc      structure, Info.plist, strict signature validity, reviewed (empty) entitlements
signed     plus Developer ID authority, one Team ID, hardened runtime and secure timestamp on
           every Mach-O
notarized  plus stapled tickets and a Gatekeeper assessment of "Notarized Developer ID"
"""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CODE = ('Contents/Frameworks/libBooksCore.dylib', 'Contents/Frameworks/libBooksPlatform.dylib',
        'Contents/MacOS/books-diagnostic', 'Contents/MacOS/BooksPresence')
failures = []


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def check(condition, message):
    print(('ok    ' if condition else 'FAIL  ') + message)
    if not condition:
        failures.append(message)


def entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(path)], capture_output=True)
    xml = result.stdout.strip()
    return plistlib.loads(xml) if xml else {}


def main():
    args = sys.argv[1:]
    level = 'notarized'
    if '--level' in args:
        index = args.index('--level')
        level = args[index + 1]
        del args[index:index + 2]
    if level not in ('adhoc', 'signed', 'notarized') or not 1 <= len(args) <= 2:
        sys.exit(__doc__)
    app = Path(args[0])
    dmg = Path(args[1]) if len(args) == 2 else None
    reviewed = plistlib.loads((ROOT / 'assets/Stillleaf.entitlements').read_bytes())

    status, output = run(sys.executable, str(ROOT / 'scripts/release/check-info-plist.py'),
                         str(app / 'Contents/Info.plist'), *(['--release'] if level != 'adhoc' else []))
    check(status == 0, 'Info.plist release checks' + ('' if status == 0 else '\n' + output.strip()))
    status, output = run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
    check(status == 0, 'codesign --verify --deep --strict' + ('' if status == 0 else '\n' + output.strip()))

    teams = set()
    for relative in CODE:
        path = app / relative
        _, details = run('codesign', '-d', '--verbose=4', str(path))
        check(entitlements(path) == reviewed, f'{relative}: entitlements match assets/Stillleaf.entitlements')
        if level == 'adhoc':
            continue
        flags = re.search(r'^CodeDirectory .*?\bflags=0x([0-9a-f]+)', details, re.M)
        check(bool(flags) and int(flags.group(1), 16) & 0x10000 != 0, f'{relative}: hardened runtime')
        check('Authority=Developer ID Application:' in details, f'{relative}: Developer ID Application authority')
        check(re.search(r'^Timestamp=', details, re.M) is not None, f'{relative}: secure timestamp')
        team = re.search(r'^TeamIdentifier=(\S+)', details, re.M)
        teams.add(team.group(1) if team else None)
    if level != 'adhoc':
        check(len(teams) == 1 and None not in teams, f'one Team ID across all code ({", ".join(map(str, teams))})')

    if level == 'notarized':
        status, output = run('xcrun', 'stapler', 'validate', str(app))
        check(status == 0, 'app has a stapled notarization ticket')
        status, output = run('spctl', '--assess', '--type', 'execute', '--verbose=4', str(app))
        check(status == 0 and 'source=Notarized Developer ID' in output, 'Gatekeeper accepts the app as Notarized Developer ID')
    if dmg:
        status, output = run('hdiutil', 'verify', '-quiet', str(dmg))
        check(status == 0, f'{dmg.name}: image checksum')
        if level != 'adhoc':
            status, output = run('codesign', '--verify', '--strict', '--verbose=2', str(dmg))
            check(status == 0, f'{dmg.name}: image signature')
        if level == 'notarized':
            status, output = run('xcrun', 'stapler', 'validate', str(dmg))
            check(status == 0, f'{dmg.name}: stapled notarization ticket')
            status, output = run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', str(dmg))
            check(status == 0 and 'source=Notarized Developer ID' in output, f'{dmg.name}: Gatekeeper accepts the image')

    if failures:
        sys.exit(f'{len(failures)} release check(s) failed at level {level}')
    print(f'All release checks passed at level {level}')


if __name__ == '__main__':
    main()
