import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createField} from '../src/vines.js';
import {createLiving, windAt, swayOf, STEP_MS, WITHER_MS, LIVE_CELLS, SHOOT_CELLS, MAX_DT, FRAME_MS} from '../src/living.js';

const COLUMNS = 120, ROWS = 44, CW = 7.8, CH = 16, WIDTH = COLUMNS * CW, HEIGHT = ROWS * CH;
const margins = (x, y) => x < 28 || x >= 92;
const zones = [{left: 14, top: 70, right: 28 * CW - 16, bottom: HEIGHT - 20}, {left: 92 * CW + 16, top: 70, right: WIDTH - 14, bottom: HEIGHT - 20}];
const page = {left: 28 * CW - 16, right: 92 * CW + 16, top: -Infinity, bottom: Infinity};

/** A small deterministic random source, so a run of the model is repeatable. */
function seeded(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6D2B79F5) >>> 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

/** The progress-driven garden the live growth layers on top of. */
function mainGarden(seed = 5) {
  const field = createField({columns: COLUMNS, rows: ROWS, cellWidth: CW, cellHeight: CH, seed, maxCells: 1500});
  field.allows = margins;
  for (const x of [3, 9, 14, 20, 96, 102, 108, 114]) field.plant({x, y: ROWS - 1, heading: -Math.PI / 2, life: 40, bias: -Math.PI / 2, biasStrength: 0.045, branchChance: 0.09, branchLife: 16, hue: x});
  field.growToCompletion(20000);
  return field;
}

function setup({seed = 1, pace = 1, dark = false, avoid = [page], key = 'one'} = {}) {
  const field = mainGarden(), living = createLiving({random: seeded(seed), pace});
  living.attach({field, columns: COLUMNS, rows: ROWS, cw: CW, ch: CH, width: WIDTH, height: HEIGHT, key, zones, avoid, dark});
  return {field, living};
}
const run = (living, ms, every = 66) => { for (let t = 0; t < ms; t += every) living.advance(every); };

test('wind comes in bands: a point sees calm and gusts, always between 0 and 1', () => {
  const samples = [];
  for (let t = 0; t < 120; t += 0.5) samples.push(windAt(300, 400, t));
  assert.ok(samples.every(w => w >= 0 && w <= 1), 'wind left the 0..1 range');
  assert.ok(samples.some(w => w === 0), 'there was never a calm moment');
  assert.ok(samples.some(w => w > 0.5), 'there was never a gust');
  assert.equal(windAt(10, 20, 3), windAt(10, 20, 3));
  // Wind varies across the window too: a gust is a band, not the whole margin at once.
  const across = new Set(); for (let x = 0; x < 1400; x += 50) across.add(windAt(x, 400, 8).toFixed(3));
  assert.ok(across.size > 3, 'the wind was the same everywhere');
});

test('wind flutters leaves, nudges blooms and never moves a stem', () => {
  assert.deepEqual(swayOf('stem', 1, CW), {dx: 0, flip: 0});
  assert.deepEqual(swayOf('leaf', 0, CW), {dx: 0, flip: 0});
  const leaf = swayOf('leaf', 1, CW), bloom = swayOf('bloom', 1, CW);
  assert.equal(leaf.flip, 1);
  assert.ok(leaf.dx > 0 && leaf.dx <= CW * 0.3 + 0.25, `leaf leaned ${leaf.dx}`);
  assert.equal(bloom.flip, 0);
  assert.ok(bloom.dx > 0 && bloom.dx < leaf.dx, `bloom leaned ${bloom.dx}`);
  // Poses come in quarter steps, so a slow gust repaints a leaf only when it visibly changes.
  for (const w of [0.12, 0.37, 0.61]) assert.equal(swayOf('leaf', w, CW).dx * 4 % 1, 0);
});

test('a new shoot grows from an existing stem, one step at a time, and never over the page', () => {
  const {field, living} = setup({pace: 1});
  assert.equal(living.counts().shoots, 0);
  run(living, 8000);
  assert.equal(living.counts().shoots, 1, 'no shoot started in the first seconds');
  const sizes = [];
  for (let i = 0; i < 12; i++) { run(living, STEP_MS); sizes.push(living.entries.size); }
  assert.ok(sizes.at(-1) > 3, `the shoot grew only ${sizes.at(-1)} cells`);
  assert.ok(sizes.every((n, i) => i === 0 || n >= sizes[i - 1]), `a growing shoot lost cells: ${sizes}`);
  assert.ok(sizes.every((n, i) => i === 0 || n - sizes[i - 1] <= 8), `the shoot did not grow slowly: ${sizes}`);
  for (const [key, {cell}] of living.entries) {
    assert.ok(margins(cell.x, cell.y), `a live cell at ${cell.x},${cell.y} is over the page`);
    assert.ok(!field.cells.has(key), 'a live cell sits on a settled one');
    assert.equal(key, cell.y * COLUMNS + cell.x);
  }
});

test('old growth recycles: the garden keeps its density for half an hour and the oldest shoot withers first', () => {
  const {living} = setup({pace: 30, seed: 3});
  let peak = 0, firstShoot = null, firstGone = null;
  for (let i = 0; i < 30 * 60 * 15; i++) {
    living.advance(FRAME_MS);
    const counts = living.counts();
    peak = Math.max(peak, living.entries.size);
    if (!firstShoot && living.shoots.length) firstShoot = living.shoots[0];
    if (firstShoot && !firstGone && !living.shoots.includes(firstShoot)) firstGone = i;
    assert.ok(counts.cells <= LIVE_CELLS + 3 * SHOOT_CELLS, `the live garden grew past its budget: ${counts.cells} cells`);
  }
  const counts = living.counts();
  assert.ok(counts.recycled >= 3, `only ${counts.recycled} shoots were recycled in half an hour`);
  assert.ok(firstGone !== null, 'the oldest shoot never withered away');
  assert.ok(counts.cells >= LIVE_CELLS / 2, `the live garden thinned out to ${counts.cells} cells`);
  assert.ok(peak > LIVE_CELLS / 2, `the live garden peaked at only ${peak} cells`);
});

test('a withering shoot lets go from its tip back to its stem, then frees its cells', () => {
  const {living} = setup({pace: 30, seed: 4});
  let withering = null;
  for (let i = 0; i < 20 * 60 * 15 && !withering; i++) { living.advance(FRAME_MS); withering = living.shoots.find(s => s.state === 'wither'); }
  assert.ok(withering, 'no shoot ever started to wither');
  const cells = [...living.entries.values()].filter(e => e.shoot === withering && e.dying > 0).sort((a, b) => a.cell.step - b.cell.step);
  assert.ok(cells.length >= 5);
  for (let i = 1; i < cells.length; i++) assert.ok(cells[i].dying <= cells[i - 1].dying, 'a cell nearer the stem withered before one nearer the tip');
  const span = cells[0].dying - cells.at(-1).dying;
  assert.ok(span > 0 && span <= WITHER_MS, `the branch withered over ${span} ms`);
  const keys = cells.map(e => e.cell.y * COLUMNS + e.cell.x);
  for (let i = 0; i < 40 * 15 && living.shoots.includes(withering); i++) living.advance(FRAME_MS);
  assert.ok(!living.shoots.includes(withering), 'a withered shoot stayed in the garden');
  for (const key of keys) assert.ok(!living.entries.has(key), 'a withered cell was not freed');
});

test('a wilting leaf or bloom sometimes lets go of a spore', () => {
  const {living} = setup({pace: 30, seed: 6});
  let spores = 0;
  for (let i = 0; i < 20 * 60 * 15; i++) { living.advance(FRAME_MS); spores = Math.max(spores, living.particles.filter(p => p.kind === 'spore').length); }
  assert.ok(spores > 0, 'no spores came off withering growth');
});

test('a bloom now and then sheds a petal that tumbles down and fades before it reaches anything', () => {
  const {living} = setup({pace: 20, seed: 7});
  const seen = new Map();
  for (let i = 0; i < 4 * 60 * 15; i++) {
    living.advance(FRAME_MS);
    for (const p of living.particles) if (p.kind === 'petal') {
      const first = seen.get(p) ?? {y: p.y, peak: 0};
      first.peak = Math.max(first.peak, p.alpha); first.last = p; first.lastY = p.y;
      seen.set(p, first);
    }
    assert.ok(living.particles.filter(p => p.kind === 'petal').length <= 3, 'too many petals at once');
  }
  assert.ok(seen.size >= 3, `only ${seen.size} petals fell in four minutes`);
  for (const f of seen.values()) { assert.ok(f.lastY > f.y, 'a petal did not fall'); assert.ok(f.peak > 0.3, 'a petal never showed'); }
});

test('particles fade out in the two cells around the page card', () => {
  const everywhere = {left: -1e5, right: 1e5, top: -1e5, bottom: 1e5};
  const {living} = setup({pace: 20, seed: 7, dark: true, avoid: [everywhere]});
  run(living, 60000);
  assert.ok(living.particles.length + living.flies.length > 0);
  for (const p of [...living.particles, ...living.flies]) assert.ok(p.alpha < 0.01, `a particle showed at ${p.alpha} inside the keep-clear area`);
});

test('fireflies appear in dark themes only, two to a margin, and stay in the margins', () => {
  const {living} = setup({dark: false});
  run(living, 6000);
  assert.equal(living.flies.length, 0, 'fireflies came out in a light theme');
  living.setDark(true);
  run(living, 20000);
  assert.equal(living.flies.length, 4);
  assert.ok(living.flies.every(f => f.alpha >= 0 && f.alpha <= 1));
  assert.ok(living.flies.some(f => f.alpha > 0.1), 'no firefly ever lit');
  for (let i = 0; i < 600; i++) {
    living.advance(FRAME_MS);
    for (const f of living.flies) assert.ok(!(f.x > page.left + 8 && f.x < page.right - 8) || f.alpha < 0.05, `a firefly glowed over the page at ${f.x}`);
  }
  living.setDark(false);
  run(living, 8000);
  assert.equal(living.flies.length, 0, 'fireflies stayed after the theme turned light');
});

test('a long gap, like a hidden window, never makes the garden leap ahead', () => {
  const {living} = setup({pace: 1});
  run(living, 4000);
  const before = {time: living.time, ...living.counts()};
  living.advance(10 * 60 * 1000);
  assert.ok(living.time - before.time <= MAX_DT, `the clock jumped ${living.time - before.time} ms`);
  assert.ok(living.counts().cells - before.cells < 12, 'a hidden minute grew a burst of cells');
});

test('regrowing the same layout keeps the live shoots; another layout starts over', () => {
  const {field, living} = setup({pace: 5, seed: 8, key: 'wide'});
  run(living, 30000);
  const kept = living.entries.size;
  assert.ok(kept > 5);
  living.attach({field, columns: COLUMNS, rows: ROWS, cw: CW, ch: CH, width: WIDTH, height: HEIGHT, key: 'wide', zones, avoid: [page], dark: false});
  assert.equal(living.entries.size, kept, 'the same layout lost its live shoots');
  living.attach({field, columns: COLUMNS, rows: ROWS, cw: CW, ch: CH, width: WIDTH, height: HEIGHT, key: 'narrow', zones, avoid: [page], dark: false});
  assert.equal(living.entries.size, 0, 'a new layout kept shoots grown for the old one');
  assert.equal(living.counts().shoots, 0);
});

test('a live shoot whose stem is gone, or whose cells the settled garden now needs, gives way', () => {
  const {field, living} = setup({pace: 5, seed: 9});
  run(living, 30000);
  const root = [...living.entries.values()][0];
  assert.ok(root);
  // The settled garden grows over a live cell: the live cell yields at once.
  const [key, taken] = [...living.entries][0];
  field.cells.set(key, {...taken.cell, kind: 'stem'});
  living.attach({field, columns: COLUMNS, rows: ROWS, cw: CW, ch: CH, width: WIDTH, height: HEIGHT, key: 'one', zones, avoid: [page], dark: false});
  assert.ok(!living.entries.has(key), 'a live cell stayed on a settled cell');
});

test('reset forgets everything', () => {
  const {living} = setup({pace: 20, seed: 2, dark: true});
  run(living, 20000);
  assert.ok(living.entries.size + living.flies.length > 0);
  living.reset();
  assert.deepEqual(living.counts(), {shoots: 0, cells: 0, growing: 0, withering: 0, recycled: 0, petals: 0, spores: 0, flies: 0});
  assert.equal(living.particles.length, 0);
});
