#!/usr/bin/env python3
"""Check actual packaged Mach-O metadata, rather than trusting compiler logs.

Usage: check-package-sdk.py APP SDK_VERSION [ARCH ...]
Every slice of every packaged binary must record macOS 13.0 as its minimum and the
linked SDK. Listing architectures (for example `arm64 x86_64` for a universal release)
also requires exactly those slices.
"""
import struct
import sys
from pathlib import Path

CPU_NAMES = {0x0100000C: 'arm64', 0x01000007: 'x86_64'}


def slices(data):
    """Yields (architecture, thin Mach-O bytes) for thin or fat files."""
    magic = struct.unpack_from('>I', data)[0]
    if magic in (0xcafebabe, 0xcafebabf):
        wide = magic == 0xcafebabf
        count = struct.unpack_from('>I', data, 4)[0]
        offset = 8
        for _ in range(count):
            if wide:
                cpu, _, start, size, _, _ = struct.unpack_from('>iiQQII', data, offset)
                offset += 32
            else:
                cpu, _, start, size, _ = struct.unpack_from('>iiIII', data, offset)
                offset += 20
            yield CPU_NAMES.get(cpu & 0xFFFFFFFF, hex(cpu)), data[start:start + size]
    else:
        cpu = struct.unpack_from('<i', data, 4)[0]
        yield CPU_NAMES.get(cpu & 0xFFFFFFFF, hex(cpu)), data


def build_versions(data, relative):
    header = struct.unpack_from('<8I', data)
    assert header[0] == 0xfeedfacf, f'{relative}: expected 64-bit Mach-O slices'
    offset, versions = 32, []
    for _ in range(header[4]):
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0x32:  # LC_BUILD_VERSION
            _, _, platform, minimum, sdk, _ = struct.unpack_from('<6I', data, offset)
            version = lambda value: (value >> 16, value >> 8 & 255, value & 255)
            versions.append((platform, version(minimum), version(sdk)))
        offset += size
    return versions


app, expected_sdk = Path(sys.argv[1]), tuple(map(int, sys.argv[2].split('.')))
expected_sdk = (expected_sdk + (0, 0))[:3]
expected_arches = sorted(sys.argv[3:])
for relative in ('Contents/MacOS/BooksPresence', 'Contents/MacOS/books-diagnostic',
                 'Contents/Frameworks/libBooksCore.dylib', 'Contents/Frameworks/libBooksPlatform.dylib'):
    found = []
    for arch, data in slices((app / relative).read_bytes()):
        versions = build_versions(data, f'{relative} ({arch})')
        assert versions == [(1, (13, 0, 0), expected_sdk)], f'{relative} ({arch}): incorrect deployment/SDK metadata: {versions}'
        found.append(arch)
    if expected_arches:
        assert sorted(found) == expected_arches, f'{relative}: architectures {found}, expected {expected_arches}'
    print(f'package-sdk: {relative}: {"+".join(found)}; macOS minimum 13.0; linked SDK {sys.argv[2]}')
