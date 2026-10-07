import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createField, vinePalette, gardenSeed, backdropColor, cardColors, contrastRatio} from '../src/vines.js';
import {THEMES} from '../src/appearance.js';

function garden(seed, {columns = 120, rows = 44, budget = Infinity, allows} = {}) {
  const field = createField({columns, rows, cellWidth: 7.8, cellHeight: 16, seed, maxCells: 2400});
  field.budget = budget;
  if (allows) field.allows = allows;
  for (let i = 0; i < 9; i++) field.plant({x: 6 + Math.floor(i * columns / 10), y: rows - 1, heading: -Math.PI / 2, life: 46, bias: -Math.PI / 2, biasStrength: 0.035, hue: i, branchChance: 0.085, branchLife: 18});
  field.growToCompletion(20000);
  return field;
}
const signature = field => JSON.stringify([...field.cells.entries()].sort((a, b) => a[0] - b[0]).map(([k, c]) => [k, c.glyph, c.kind]));

test('the same seed grows the same garden; another seed grows another', () => {
  const a = garden(42), b = garden(42), c = garden(43);
  assert.ok(a.cells.size > 200, `grew ${a.cells.size}`);
  assert.equal(signature(a), signature(b));
  assert.notEqual(signature(a), signature(c));
  const kinds = new Set([...a.cells.values()].map(c => c.kind));
  assert.ok(kinds.has('leaf') && kinds.has('bloom'));
});

test('no cell lands in a refused region', () => {
  const refused = (x, y) => x >= 40 && x < 80 && y >= 10 && y < 30;
  const field = garden(7, {allows: (x, y) => !refused(x, y)});
  for (const cell of field.cells.values()) assert.ok(!refused(cell.x, cell.y), `${cell.x},${cell.y}`);
});

test('a larger budget starts with the smaller budget’s cells', () => {
  const short = garden(5, {budget: 300}), long = garden(5, {budget: 900});
  assert.ok(short.cells.size >= 300 && short.cells.size <= 304, `${short.cells.size}`);
  for (const key of short.cells.keys()) assert.ok(long.cells.has(key));
});

test('consecutive stems of one tip always touch', () => {
  const field = createField({columns: 60, rows: 30, cellWidth: 7.8, cellHeight: 16, seed: 3, maxCells: 400});
  field.plant({x: 2, y: 15, heading: 0, life: 40, branchChance: 0, leafChance: 0, bloomChance: 0});
  field.growToCompletion(200);
  const stems = [...field.cells.values()].filter(c => c.kind === 'stem').sort((a, b) => a.step - b.step);
  assert.ok(stems.length > 20);
  for (let i = 1; i < stems.length; i++) {
    assert.ok(Math.abs(stems[i].x - stems[i - 1].x) <= 1 && Math.abs(stems[i].y - stems[i - 1].y) <= 1, `gap at ${i}`);
  }
});

test('a path follower without wobble stays on its path', () => {
  const field = createField({columns: 40, rows: 20, cellWidth: 7.2, cellHeight: 15, seed: 4, maxCells: 400});
  const path = Array.from({length: 121}, (_, i) => ({x: 20 + Math.cos(i / 120 * Math.PI) * 15, y: 10 + Math.sin(i / 120 * Math.PI) * 7}));
  field.plant({x: 35, y: 10, life: 9999, leafChance: 0, bloomChance: 0, path, wobble: 0});
  field.growToCompletion(500);
  assert.ok(field.cells.size > 20);
  for (const c of field.cells.values()) assert.ok(path.some(p => Math.abs(p.x - c.x) <= 1 && Math.abs(p.y - c.y) <= 1));
});

test('heads report live tips and disappear once grown', () => {
  const field = createField({columns: 60, rows: 30, cellWidth: 7.8, cellHeight: 16, seed: 8, maxCells: 400});
  field.plant({x: 30, y: 29, branchChance: 0});
  field.step();
  assert.ok(field.isGrowing);
  assert.equal(field.heads().length, 1);
  field.growToCompletion(1000);
  assert.ok(!field.isGrowing);
  assert.equal(field.heads().length, 0);
});

test('daily seeds are stable within a day and differ across days', () => {
  assert.equal(gardenSeed('reader', '2026-10-04'), gardenSeed('reader', '2026-10-04'));
  assert.notEqual(gardenSeed('reader', '2026-10-04'), gardenSeed('reader', '2026-10-05'));
});

test('the vine palette stays legible on the backdrop it grows on', () => {
  for (const [paper, accent, ink, dark] of [['#fbfcfa', '#176650', '#183d33', false], ['#f3e9d6', '#8a5a1f', '#4a3a22', false], ['#141e1a', '#6fd4ae', '#e6f1eb', true], ['#000000', '#86abff', '#ececef', true]]) {
    const backdrop = backdropColor(paper, ink), palette = vinePalette({accent, ink, paper, muted: ink, backdrop}, dark);
    for (const color of [...palette.stems, ...palette.leaves, ...palette.blooms]) assert.ok(contrastRatio(color, backdrop) >= 3, `${color} on ${backdrop}`);
  }
});

test('every reader theme gets a backdrop that tells the page card from its surroundings and keeps near vines at 3:1', () => {
  for (const t of THEMES) {
    const backdrop = backdropColor(t.background, t.text), dark = t.scheme === 'dark';
    assert.notEqual(backdrop.toLowerCase(), t.background.toLowerCase(), `${t.id}: the backdrop is the page colour`);
    assert.ok(contrastRatio(backdrop, t.background) >= 1.1, `${t.id}: the card edge would not read (${contrastRatio(backdrop, t.background).toFixed(3)})`);
    // Light pages sit on a darker backdrop, as in the mockup; only the near-black pages are lifted instead.
    if (!dark) assert.ok(contrastRatio('#ffffff', backdrop) >= contrastRatio('#ffffff', t.background), `${t.id}: the backdrop is lighter than the card`);
    const palette = vinePalette({accent: t.link, ink: t.text, paper: t.background, muted: t.muted, backdrop}, dark);
    for (const color of [...palette.stems, ...palette.leaves]) assert.ok(contrastRatio(color, backdrop) >= 3, `${t.id}: ${color} on ${backdrop}`);
    const shades = cardColors(t.background, t.text);
    for (const value of Object.values(shades)) assert.match(value, /^rgba\(\d+,\d+,\d+,[\d.]+\)$/);
  }
});

test('stems and leaves are drawn from several greens and teals, blooms from pink, orange and violet hues', () => {
  const palette = vinePalette({accent: '#176650', ink: '#183d33', paper: '#fbfcfa', muted: '#4b6a5e'}, false);
  assert.ok(new Set(palette.stems).size >= 4 && new Set(palette.leaves).size >= 5 && new Set(palette.blooms).size >= 4);
  const hues = palette.blooms.map(hex => { const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16)); const max = Math.max(r, g, b), d = max - Math.min(r, g, b); return d === 0 ? 0 : (max === r ? ((g - b) / d + 6) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4) * 60; });
  assert.ok(hues.some(h => h > 270 || h < 30), `no pink or red bloom in ${palette.blooms}`);
  assert.ok(hues.some(h => h >= 25 && h < 60), `no orange or gold bloom in ${palette.blooms}`);
});

test('a grey accent keeps the vines grey-green instead of red', () => {
  const palette = vinePalette({accent: '#202020', ink: '#202020', paper: '#ffffff', muted: '#202020'}, false);
  for (const hex of [...palette.stems, ...palette.leaves]) { const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16)); assert.ok(Math.max(r, g, b) - Math.min(r, g, b) < 60, `${hex} is not neutral`); }
});

test('cells remember which branch generation grew them, for depth', () => {
  const field = garden(11);
  const generations = new Set([...field.cells.values()].map(c => c.generation));
  assert.ok(generations.has(0) && generations.has(1), `generations: ${[...generations]}`);
});
