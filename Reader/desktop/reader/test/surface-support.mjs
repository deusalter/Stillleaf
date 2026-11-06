// Shared by the surface pixel test and scripts/render-reader-surface.mjs: a synthetic book, a page with the reader
// open at a size, a small PNG decoder (no image dependency in this package) and a colour census of a screenshot.
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {inflateSync} from 'node:zlib';
import path from 'node:path';
import {chromium, webkit} from 'playwright';

export const SIZES = [[1512, 982], [1728, 1117], [2560, 1440], [3840, 2160]];
export const MODES = {single: {scroll: false, columns: 'one'}, facing: {scroll: false, columns: 'two'}, continuous: {scroll: true, columns: 'one'}};

const prose = 'The light fell across the open book. She turned a page and settled into her chair by the window, where the garden was. Rain had come and gone in the night, and the path still shone under the hedges.';
const chapter = n => `<!doctype html><html><head><title>Chapter ${n}</title></head><body><h1>Chapter ${n}</h1>${`<p>${prose}</p>`.repeat(120)}</body></html>`;
const resource = n => ({href: `c${n}.html`, type: 'text/html', dataBase64: Buffer.from(chapter(n)).toString('base64')});
export const bookFor = (preferences = {}, editionId = 'surface-check') => ({editionId, title: 'One Surface', language: 'en', readingProgression: 'ltr', contentProgress: true,
  experimentalContinuous: true, readingOrder: [1, 2].map(n => ({href: `c${n}.html`, type: 'text/html', title: `Chapter ${n}`})), resources: [1, 2].map(resource),
  state: {schemaVersion: 1, editionId, revision: 0, position: null, preferences, bookmarks: [], annotations: []}});

export async function serve(root) {
  const server = createServer(async (req, res) => {
    try {
      const file = path.resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
      if (!file.startsWith(root + path.sep)) throw Error();
      res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.woff2': 'font/woff2'}[path.extname(file)] ?? 'application/octet-stream');
      res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {url: `http://127.0.0.1:${server.address().port}/index.html`, close: () => { server.closeAllConnections(); server.close(); }};
}

export const launchBrowser = engine => engine === 'webkit' ? webkit.launch()
  : chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});

/** A page with the reader open, optionally under the native chrome as the Mac host connects it. */
export async function openReader(browser, url, {width, height, preferences = {}, native = true, gardenMode = 'still', editionId, dark = false, reducedMotion = 'reduce'}) {
  const context = await browser.newContext({viewport: {width, height}, reducedMotion, colorScheme: dark ? 'dark' : 'light'});
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => { if (!/ResizeObserver loop/.test(String(error))) errors.push(String(error)); });
  await page.addInitScript(mode => { window.__stillleafGardenMode = mode; window.__stillleafGardenDebug = true; }, gardenMode);
  await page.goto(url);
  await page.waitForFunction(() => window.StillleafReader);
  const book = bookFor(preferences, editionId);
  await page.evaluate(input => window.StillleafReader.open(input), book);
  if (native) await page.evaluate(id => window.StillleafReader.nativeControl({version: 1, editionId: id, id: 1, command: 'activate'}), book.editionId);
  return {page, context, errors, editionId: book.editionId};
}

/** Lets a preference change land: the frames, the footer and any garden regrow. */
export async function settle(page, ms = 450) {
  await page.waitForFunction(() => [...document.querySelectorAll('#reader iframe')].some(frame => frame.contentDocument?.body?.textContent.length > 0));
  await page.waitForTimeout(ms);
}

/** Text and vines removed, without moving anything: what remains is the surface alone. */
export async function hideInk(page, {garden = true} = {}) {
  await page.evaluate(({garden}) => {
    const css = `*,*::before,*::after{color:transparent!important;-webkit-text-fill-color:transparent!important;text-decoration-color:transparent!important;caret-color:transparent!important}`;
    const add = doc => { if (doc.getElementById('surface-ink')) return; const s = doc.createElement('style'); s.id = 'surface-ink'; s.textContent = css; doc.head.append(s); };
    add(document);
    for (const frame of document.querySelectorAll('iframe')) if (frame.contentDocument?.head) add(frame.contentDocument);
    if (garden) for (const id of ['garden', 'garden-spine', 'garden-footer']) { const c = document.getElementById(id); if (c) c.style.visibility = 'hidden'; }
  }, {garden});
  await page.waitForTimeout(60);
}

export async function showInk(page) {
  await page.evaluate(() => {
    for (const doc of [document, ...[...document.querySelectorAll('iframe')].map(frame => frame.contentDocument).filter(Boolean)]) doc.getElementById('surface-ink')?.remove();
    for (const id of ['garden', 'garden-spine', 'garden-footer']) { const c = document.getElementById(id); if (c) c.style.visibility = ''; }
  });
}

/** Decodes an 8-bit, non-interlaced RGB or RGBA PNG: what Playwright's screenshots are. */
export function decodePNG(buffer) {
  let offset = 8, width, height, channels; const data = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset), type = buffer.toString('latin1', offset + 4, offset + 8), body = offset + 8;
    if (type === 'IHDR') {
      width = buffer.readUInt32BE(body); height = buffer.readUInt32BE(body + 4);
      const depth = buffer[body + 8], color = buffer[body + 9], interlace = buffer[body + 12];
      if (depth !== 8 || interlace !== 0 || ![2, 6].includes(color)) throw Error(`Unsupported PNG: depth ${depth}, colour ${color}, interlace ${interlace}`);
      channels = color === 6 ? 4 : 3;
    } else if (type === 'IDAT') data.push(buffer.subarray(body, body + length));
    else if (type === 'IEND') break;
    offset = body + length + 4;
  }
  const raw = inflateSync(Buffer.concat(data)), stride = width * channels, pixels = Buffer.alloc(height * stride);
  for (let y = 0, source = 0; y < height; y++) {
    const filter = raw[source++], row = y * stride, above = row - stride;
    for (let x = 0; x < stride; x++, source++) {
      const a = x >= channels ? pixels[row + x - channels] : 0, b = y ? pixels[above + x] : 0, c = x >= channels && y ? pixels[above + x - channels] : 0;
      let predicted = 0;
      if (filter === 1) predicted = a; else if (filter === 2) predicted = b; else if (filter === 3) predicted = (a + b) >> 1;
      else if (filter === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); predicted = pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      pixels[row + x] = (raw[source] + predicted) & 255;
    }
  }
  return {width, height, channels, pixels};
}

export const hexAt = (image, x, y) => {
  const i = (y * image.width + x) * image.channels, h = v => v.toString(16).padStart(2, '0');
  return `#${h(image.pixels[i])}${h(image.pixels[i + 1])}${h(image.pixels[i + 2])}`;
};

/** Every colour in a screenshot, most common first, with where the first pixel of each was found. */
export function census(image) {
  const counts = new Map(), {width, height, channels, pixels} = image;
  for (let i = 0, n = width * height; i < n; i++) {
    const key = (pixels[i * channels] << 16) | (pixels[i * channels + 1] << 8) | pixels[i * channels + 2];
    const seen = counts.get(key);
    if (seen) seen.count++; else counts.set(key, {count: 1, first: i});
  }
  return [...counts].sort((a, b) => b[1].count - a[1].count).map(([key, {count, first}]) => ({
    color: '#' + key.toString(16).padStart(6, '0'), count, share: count / (width * height), x: first % width, y: Math.floor(first / width)}));
}
