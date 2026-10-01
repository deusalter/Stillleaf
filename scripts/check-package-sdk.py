#!/usr/bin/env python3
"""Check actual packaged Mach-O metadata, rather than trusting compiler logs."""
import struct
import sys
from pathlib import Path

app, expected_sdk = Path(sys.argv[1]), tuple(map(int, sys.argv[2].split('.')))
expected_sdk = (expected_sdk + (0, 0))[:3]
for relative in ('Contents/MacOS/BooksPresence', 'Contents/MacOS/books-diagnostic',
                 'Contents/Frameworks/libBooksCore.dylib', 'Contents/Frameworks/libBooksPlatform.dylib'):
    data = (app / relative).read_bytes()
    header = struct.unpack_from('<8I', data)
    assert header[0] == 0xfeedfacf, f'{relative}: expected thin 64-bit Mach-O'
    offset, versions = 32, []
    for _ in range(header[4]):
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0x32:  # LC_BUILD_VERSION
            _, _, platform, minimum, sdk, _ = struct.unpack_from('<6I', data, offset)
            version = lambda value: (value >> 16, value >> 8 & 255, value & 255)
            versions.append((platform, version(minimum), version(sdk)))
        offset += size
    assert versions == [(1, (13, 0, 0), expected_sdk)], f'{relative}: incorrect deployment/SDK metadata: {versions}'
    print(f'package-sdk: {relative}: macOS minimum 13.0; linked SDK {sys.argv[2]}')
