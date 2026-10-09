/** The Living garden's motion model (design/dynamic-motion, "Living garden"): new shoots that keep growing slowly beside the
 * reading-driven garden, old growth that withers away again, wind that flutters leaves, petals, spores and, in dark themes,
 * fireflies. Pure state with no canvas or DOM: garden.js advances it a few times a second and paints only what changed.
 * Everything runs on its own clock that ignores gaps longer than MAX_DT, so a window that was hidden never catches up in a burst. */
import {createField} from './vines.js';

export const FRAME_MS = 1000 / 15;
export const STEP_MS = 1500, WITHER_MS = 20000, SHOOT_EVERY = 40000, FIRST_SHOOT = 3000, PETAL_EVERY = 18000;
export const LIVE_CELLS = 120, SHOOT_CELLS = 40, MAX_GROWING = 3, MAX_PETALS = 3, FLIES_PER_ZONE = 2;
export const MAX_DT = 100, FADE_MS = 700, WITHER_FADE = 900, KEEP_CLEAR_FADE = 16;
const PETALS = ["'", '`', ',', '˙'], SPORES = ['·', '∙', '°', '˚'];
export const REST = Object.freeze({dx: 0, flip: 0});
const TAU = Math.PI * 2;
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const quarter = value => Math.round(value * 4) / 4;

function hash(x, y) { let h = (x * 374761393 + y * 668265263) | 0; h = (h ^ (h >>> 13)) * 1274126177; return ((h ^ (h >>> 16)) >>> 0) / 4294967296; }
function noise(x, y) {
  const xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi, u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
  const a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1);
  return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
}

/** Slow bands of wind: 0 in the calm, up to 1 in a gust. */
export const windAt = (x, y, seconds) => smooth(0.5, 0.88, noise(x * 0.0055 - seconds * 0.32, y * 0.011 + seconds * 0.04));

/** How a gust of strength `wind` moves a cell: leaves lean and flip to their fluttered glyph, blooms nudge, stems stay put.
 *  Poses come in quarter steps so a slow gust repaints a cell only when it visibly changes. */
export function swayOf(kind, wind, cellWidth) {
  if (wind <= 0.01 || kind === 'stem') return REST;
  if (kind === 'leaf') return {dx: quarter(wind * cellWidth * 0.3), flip: quarter(smooth(0.3, 0.75, wind))};
  return {dx: quarter(wind * cellWidth * 0.18), flip: 0};
}

/**
 * @param {object} [options]
 * @param {() => number} [options.random] a [0, 1) source, injectable so a run is repeatable
 * @param {number} [options.pace] 1 is real time; larger compresses every interval, like the mockup's Fast preview
 */
export function createLiving({random = Math.random, pace = 1} = {}) {
  const every = ms => ms / pace * (0.6 + random() * 0.8);
  let garden = null, dark = false, flyAlpha = 0, nextShoot = 0, nextPetal = 0;
  const living = {time: 0, entries: new Map(), shoots: [], particles: [], flies: [], recycled: 0, attach, advance, reset, setDark, counts, alpha};

  /** Live growth opacity: fades in when born and out when its branch withers. */
  function alpha(entry) {
    return smooth(0, FADE_MS, living.time - entry.born) * (entry.dying ? 1 - smooth(entry.dying, entry.dying + WITHER_FADE, living.time) : 1);
  }

  function reset() {
    living.entries = new Map(); living.shoots = []; living.particles = []; living.flies = []; living.recycled = 0; flyAlpha = 0;
    nextShoot = living.time + FIRST_SHOOT / pace; nextPetal = living.time + every(PETAL_EVERY);
  }

  /** A new settled garden to live beside. The same layout keeps its shoots (minus any the garden now needs); another starts over. */
  function attach(next) {
    const same = garden?.key === next.key;
    garden = next; dark = next.dark ?? dark;
    if (!same) { reset(); return; }
    for (const [key, entry] of [...living.entries]) if (garden.field.cells.has(key) || !garden.field.allows(entry.cell.x, entry.cell.y)) drop(key);
    for (const shoot of living.shoots) if (shoot.state !== 'wither' && !garden.field.cells.has(shoot.root)) wither(shoot);
  }

  function setDark(value) { dark = value; }

  function drop(key) {
    const entry = living.entries.get(key);
    if (!entry) return;
    living.entries.delete(key); entry.shoot.field.cells.delete(key);
  }

  const taken = (shoot, x, y) => living.shoots.some(s => s !== shoot && s.field.cells.has(y * garden.columns + x));
  const countLive = () => { let n = 0; for (const e of living.entries.values()) if (!e.dying) n++; return n; };

  /** A shoot off an existing stem: a few cells long, leaning up and out, growing a cell every STEP_MS. */
  function spawn() {
    const stems = [];
    for (const c of garden.field.cells.values()) if (c.kind === 'stem' && c.generation < 2 && c.y > 3) stems.push(c);
    if (!stems.length) return;
    const root = stems[Math.floor(random() * stems.length)], side = random() < 0.5 ? -1 : 1, {columns, rows, cw, ch} = garden;
    const field = createField({columns, rows, cellWidth: cw, cellHeight: ch, seed: 1 + Math.floor(random() * 2147483646), maxCells: SHOOT_CELLS});
    const shoot = {field, state: 'grow', born: living.time, root: root.y * columns + root.x, nextStep: living.time + STEP_MS / pace};
    field.maxTips = 6;
    field.allows = (x, y) => garden.field.allows(x, y) && !garden.field.cells.has(y * columns + x) && !taken(shoot, x, y);
    field.plant({x: root.x, y: root.y, heading: -Math.PI / 2 + side * (0.55 + random() * 0.6), life: 10 + Math.floor(random() * 14), generation: root.generation + 1,
      bias: -Math.PI / 2 + side * 0.4, biasStrength: 0.03, hue: Math.floor(random() * 4), branchChance: 0.05, branchLife: 9, leafChance: 0.32, maxGeneration: 3, curl: (random() - 0.5) * 0.08});
    living.shoots.push(shoot);
  }

  function grow(shoot) {
    const {field} = shoot;
    for (let steps = 0; steps < 4 && living.time >= shoot.nextStep && shoot.state === 'grow'; steps++) {
      field.step();
      shoot.nextStep += STEP_MS / pace;
      for (const [key, cell] of field.cells) if (cell.step === field.stepCount - 1 && living.entries.get(key)?.cell !== cell) living.entries.set(key, {cell, shoot, born: living.time, dying: 0, shed: false});
      if (!field.isGrowing) shoot.state = 'settled';
    }
  }

  /** The branch lets go from its tip back to its stem; cells the same step grew go together. */
  function wither(shoot) {
    const mine = [...living.entries.values()].filter(e => e.shoot === shoot);
    shoot.state = 'wither';
    if (!mine.length) return;
    const steps = mine.map(e => e.cell.step), newest = Math.max(...steps), span = newest - Math.min(...steps) + 1;
    for (const e of mine) e.dying = living.time + (newest - e.cell.step) / span * (WITHER_MS / pace);
  }

  /** Fades particles near the page card, so wind, petals and fireflies stay at least two cells clear of the text. */
  function clearance(x, y) {
    let a = 1;
    for (const r of garden.avoid) a = Math.min(a, smooth(0, KEEP_CLEAR_FADE, Math.hypot(Math.max(r.left - x, 0, x - r.right), Math.max(r.top - y, 0, y - r.bottom))));
    return a;
  }

  function release(kind, x, y, extra) {
    living.particles.push({kind, x, y, x0: x, y0: y, alpha: 0, born: living.time, ph: random() * TAU, glyph: '', slot: 0, ...extra});
  }

  function shedPetal() {
    const blooms = [];
    for (const c of garden.field.cells.values()) if (c.kind === 'bloom') blooms.push(c);
    for (const e of living.entries.values()) if (e.cell.kind === 'bloom' && !e.dying) blooms.push(e.cell);
    if (!blooms.length || living.particles.filter(p => p.kind === 'petal').length >= MAX_PETALS) return;
    const c = blooms[Math.floor(random() * blooms.length)];
    release('petal', (c.x + 0.5) * garden.cw, (c.y + 0.6) * garden.ch, {vx: 6 + random() * 8, vy: 14 + random() * 12, life: 6500 + random() * 3000, slot: c.slot % 4});
  }

  function move(p, k) {
    const age = living.time - p.born, seconds = age / 1000;
    if (age > p.life) return false;
    if (p.kind === 'petal') {
      p.x0 += (p.vx + windAt(p.x0, p.y0, living.time / 1000) * 40) * k; p.y0 += p.vy * k;
      p.x = p.x0 + Math.sin(seconds * 1.7 + p.ph) * 9; p.y = p.y0;
      p.glyph = PETALS[Math.floor(age / 340 + p.ph) % PETALS.length];
      p.alpha = 0.85 * smooth(0, 500, age) * (1 - smooth(p.life - 1500, p.life, age));
      if (p.y > garden.height + 20 || p.x > garden.width + 60) return false;
    } else {
      p.x = p.x0 + p.vx * seconds + Math.sin(seconds * 1.3 + p.ph) * 6; p.y = p.y0 + p.vy * seconds;
      p.alpha = 0.7 * smooth(0, 800, age) * (1 - smooth(p.life - 1600, p.life, age));
    }
    p.alpha *= clearance(p.x, p.y);
    return true;
  }

  function drift(k) {
    const seconds = living.time / 1000;
    flyAlpha += ((dark ? 1 : 0) - flyAlpha) * Math.min(1, k * 2.5);
    if (dark && !living.flies.length) {
      for (const zone of garden.zones) for (let i = 0; i < FLIES_PER_ZONE; i++) {
        living.flies.push({x: zone.left + random() * (zone.right - zone.left), y: zone.top + random() * (zone.bottom - zone.top), s: random() * 50, ph: random() * TAU, om: 0.9 + random() * 1.1, zone, alpha: 0});
      }
    }
    if (!dark && flyAlpha < 0.01) { living.flies = []; return; }
    for (const f of living.flies) {
      const angle = noise(f.x * 0.006 + f.s, f.y * 0.006 + seconds * 0.12) * TAU * 2, z = f.zone;
      let vx = Math.cos(angle) * 15, vy = Math.sin(angle) * 15;
      if (f.x < z.left || f.x > z.right || f.y < z.top || f.y > z.bottom) {
        const cx = (z.left + z.right) / 2, cy = (z.top + z.bottom) / 2, d = Math.hypot(cx - f.x, cy - f.y) || 1;
        vx += (cx - f.x) / d * 22; vy += (cy - f.y) / d * 22;
      }
      f.x += vx * k; f.y += vy * k;
      f.alpha = (0.12 + 0.88 * smooth(0.45, 1, Math.sin(seconds * f.om + f.ph))) * flyAlpha * clearance(f.x, f.y);
    }
  }

  /** Moves the model on by `ms` of real time (at most MAX_DT of it counts). */
  function advance(ms) {
    if (!garden) return;
    const dt = Math.min(MAX_DT, Math.max(0, ms)), k = dt / 1000;
    living.time += dt;
    if (living.time >= nextShoot) {
      nextShoot = living.time + every(SHOOT_EVERY);
      if (living.shoots.filter(s => s.state === 'grow').length < MAX_GROWING && countLive() <= LIVE_CELLS + SHOOT_CELLS) spawn();
    }
    for (const shoot of living.shoots) if (shoot.state === 'grow') grow(shoot);
    // Past its budget, the oldest settled branch withers; the garden keeps about the same density all day.
    if (countLive() > LIVE_CELLS && !living.shoots.some(s => s.state === 'wither')) {
      const oldest = living.shoots.find(s => s.state === 'settled');
      if (oldest) wither(oldest);
    }
    for (const [key, entry] of living.entries) {
      if (!entry.dying || living.time < entry.dying) continue;
      if (!entry.shed) {
        entry.shed = true;
        if (entry.cell.kind !== 'stem' && random() < 0.5) release('spore', (entry.cell.x + 0.5) * garden.cw, entry.cell.y * garden.ch, {vx: (random() - 0.5) * 6, vy: -(6 + random() * 10), life: 4500 + random() * 4000, glyph: SPORES[Math.floor(random() * SPORES.length)]});
      }
      if (living.time > entry.dying + WITHER_FADE) drop(key);
    }
    living.shoots = living.shoots.filter(s => {
      if (s.state !== 'wither' || [...living.entries.values()].some(e => e.shoot === s)) return true;
      living.recycled++;
      return false;
    });
    if (living.time >= nextPetal) { nextPetal = living.time + every(PETAL_EVERY); shedPetal(); }
    living.particles = living.particles.filter(p => move(p, k));
    drift(k);
  }

  function counts() {
    const kinds = kind => living.particles.filter(p => p.kind === kind).length;
    return {shoots: living.shoots.length, cells: living.entries.size, growing: living.shoots.filter(s => s.state === 'grow').length,
      withering: living.shoots.filter(s => s.state === 'wither').length, recycled: living.recycled, petals: kinds('petal'), spores: kinds('spore'), flies: living.flies.length};
  }

  reset();
  return living;
}
