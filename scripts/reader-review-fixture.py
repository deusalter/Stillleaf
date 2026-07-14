#!/usr/bin/env python3
"""Create original, synthetic EPUB content for offscreen native visual checks."""
import base64
import sys
import zipfile
from pathlib import Path

out = Path(sys.argv[1])
chapters = int(sys.argv[sys.argv.index("--chapters") + 1]) if "--chapters" in sys.argv else 1
if not 1 <= chapters <= 24:
    raise ValueError("Synthetic fixture supports 1–24 chapters")
out.parent.mkdir(parents=True, exist_ok=True)
container = '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
opf = '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>The garden after rain</dc:title><dc:creator>Stillleaf visual fixture</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="style" href="styles/fixture.css" media-type="text/css"/><item id="leaf" href="images/leaf.png" media-type="image/png"/></manifest><spine><itemref idref="chapter"/></spine></package>'
chapter = '''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>The garden after rain</title><link rel="stylesheet" type="text/css" href="styles/fixture.css"/><style>p{margin:0 0 1em}blockquote{margin:1.4em 2em;font-style:italic}.poem{white-space:pre-line;text-indent:0}h1{font-size:1.8em;line-height:1.2;margin:0 0 1em}h2{font-size:1.25em}</style></head><body>
<h1>The garden after rain</h1>
<img id="fixture-figure" src="images/leaf.png" alt=""/>
<p>By morning the rain had stopped. Water rested along the lip of the clay pot, and every time a leaf moved, another drop fell into the soil. Mira brought her chair to the open door and left her book on the step.</p>
<p>She had meant to read only a few pages. <em>A few pages</em> was what she always promised herself before the kettle boiled, before the light reached the far wall, before the quiet became something she could no longer measure.</p>
<blockquote>There are places we return to because they ask so little of us. A chair. A page. The garden after rain.</blockquote>
<p>Beside the path, the rosemary had begun to flower. She wrote three things on the back of an envelope:</p>
<ul><li>Move the pot into the afternoon light.</li><li>Leave the fallen branch for the birds.</li><li>Finish the letter.</li></ul>
<h2>At the open door</h2>
<p class="poem">One drop on the stone,\none on the stair.\nThe room holds its breath;\nthe garden is there.</p>
<p>When she picked up the book again, a small mark in the margin caught her eye.<a href="#note-one" role="doc-noteref">1</a> It had been there for years. Today she understood why she had made it.</p>
<aside id="note-one" role="doc-footnote"><p>1. This original passage is a synthetic test fixture. It does not represent a user’s book or reading history.</p></aside>
</body></html>'''
if chapters > 1:
    opf = opf.replace('</manifest>', ''.join(f'<item id="chapter{i}" href="chapter{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(1, chapters)) + '</manifest>')
    opf = opf.replace('</spine>', ''.join(f'<itemref idref="chapter{i}"/>' for i in range(1, chapters)) + '</spine>')
with zipfile.ZipFile(out, 'w') as archive:
    archive.writestr('mimetype', 'application/epub+zip')
    archive.writestr('META-INF/container.xml', container)
    archive.writestr('EPUB/book.opf', opf)
    archive.writestr('EPUB/chapter.xhtml', chapter)
    # A stylesheet and image let the native smoke prove lazily served publication files.
    archive.writestr('EPUB/styles/fixture.css', '#fixture-figure{border-left:6px solid #2a6;width:24px;height:24px}')
    archive.writestr('EPUB/images/leaf.png', base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
    for i in range(1, chapters):
        archive.writestr(f'EPUB/chapter{i}.xhtml', chapter.replace('The garden after rain', f'The garden, chapter {i + 1}'))
print(out.resolve())
