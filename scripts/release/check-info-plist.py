#!/usr/bin/env python3
"""Release-blocker checks for Stillleaf's Info.plist.

Usage: check-info-plist.py PATH/TO/Info.plist [--release]

Runs for every package (scripts/package-app.sh) and again for releases with --release, which
also requires a stamped build number and an update feed URL. Exits non-zero with every problem
listed, so one run shows all blockers.
"""
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

# The identifier, executable and storage folder predate the Stillleaf name. Keeping them
# preserves existing users' Accessibility grants, login item and history (README: Data).
EXPECTED = {
    'CFBundleIdentifier': 'com.bookspresence.app',
    'CFBundleExecutable': 'BooksPresence',
    'CFBundleName': 'Stillleaf',
    'CFBundleDisplayName': 'Stillleaf',
    'CFBundlePackageType': 'APPL',
    'CFBundleInfoDictionaryVersion': '6.0',
    'LSMinimumSystemVersion': '13.0',
    'NSPrincipalClass': 'NSApplication',
    'LSUIElement': True,
}
# Apple's documented LSApplicationCategoryType values (games subcategories omitted).
CATEGORIES = {
    'business', 'developer-tools', 'education', 'entertainment', 'finance', 'games',
    'graphics-design', 'healthcare-fitness', 'lifestyle', 'medical', 'music', 'news',
    'photography', 'productivity', 'reference', 'social-networking', 'sports', 'travel',
    'utilities', 'video', 'weather',
}
# Purpose strings for protected resources Stillleaf never uses. A key here would show users a
# prompt rationale for something the app does not do (see docs/PRIVACY.md).
UNUSED_PURPOSES = {
    'NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSContactsUsageDescription',
    'NSCalendarsUsageDescription', 'NSRemindersUsageDescription', 'NSPhotoLibraryUsageDescription',
    'NSLocationUsageDescription', 'NSLocationWhenInUseUsageDescription', 'NSBluetoothAlwaysUsageDescription',
    'NSAppleEventsUsageDescription', 'NSSpeechRecognitionUsageDescription',
}


def problems(info, release, bundle):
    for key, value in EXPECTED.items():
        if info.get(key) != value:
            yield f'{key} is {info.get(key)!r}, expected {value!r}'
    version = info.get('CFBundleShortVersionString', '')
    if not re.fullmatch(r'\d+\.\d+\.\d+', str(version)):
        yield f'CFBundleShortVersionString {version!r} must be MAJOR.MINOR.PATCH'
    build = str(info.get('CFBundleVersion', ''))
    if not re.fullmatch(r'[1-9]\d*', build):
        yield f'CFBundleVersion {build!r} must be a positive integer build number'
    elif release and int(build) < 100:
        yield f'CFBundleVersion {build} looks like the unstamped committed placeholder'
    if not str(info.get('NSHumanReadableCopyright', '')).startswith('Copyright ©'):
        yield 'NSHumanReadableCopyright must be a "Copyright © YEAR HOLDER" line'
    category = str(info.get('LSApplicationCategoryType', ''))
    if category.removeprefix('public.app-category.') not in CATEGORIES:
        yield f'LSApplicationCategoryType {category!r} is not a documented category'
    icon = info.get('CFBundleIconFile')
    if not icon:
        yield 'CFBundleIconFile is missing'
    elif bundle and not (bundle / 'Contents/Resources' / icon).is_file():
        yield f'Resources/{icon} is missing from the bundle'
    for key in sorted(UNUSED_PURPOSES & info.keys()):
        yield f'{key} declares a permission Stillleaf does not use'
    feed = info.get('StillleafUpdateFeedURL')
    if feed is not None:
        url = urlparse(str(feed))
        if url.scheme != 'https' or not url.hostname or url.username or url.password:
            yield f'StillleafUpdateFeedURL {feed!r} must be a credential-free https URL'
    elif release:
        yield 'StillleafUpdateFeedURL is missing; set STILLLEAF_UPDATE_FEED_URL when packaging a release'
    if bundle and not (bundle / 'Contents/Resources/THIRD_PARTY_NOTICES.md').is_file():
        yield 'Resources/THIRD_PARTY_NOTICES.md is missing from the bundle'


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 1:
        sys.exit(__doc__)
    path = Path(args[0])
    bundle = path.parents[1] if path.parent.name == 'Contents' and path.parents[1].suffix == '.app' else None
    with path.open('rb') as handle:
        info = plistlib.load(handle)
    found = list(problems(info, '--release' in sys.argv, bundle))
    for problem in found:
        print(f'info-plist: {problem}', file=sys.stderr)
    if found:
        sys.exit(1)
    print(f'info-plist: {path}: {info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]}) OK')


if __name__ == '__main__':
    main()
